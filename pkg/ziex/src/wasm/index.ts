import { ZigJS } from "../../../../vendor/jsz/js/src";

/**
 * ZX Client Bridge - Unified JS↔WASM communication layer
 * Handles events, fetch, WebSocket, timers, and other async callbacks using jsz
 */
export const CallbackType = {
    Event: 0,
    FetchSuccess: 1,
    FetchError: 2,
    Timeout: 3,
    Interval: 4,
    WebSocketOpen: 5,
    WebSocketMessage: 6,
    WebSocketError: 7,
    WebSocketClose: 8,
} as const;

export type CallbackTypeValue = typeof CallbackType[keyof typeof CallbackType];
type CallbackHandler = (callbackType: number, id: bigint, dataRef: bigint) => void;
type FetchCompleteHandler = (fetchId: bigint, statusCode: number, bodyPtr: number, bodyLen: number, isError: number) => void;

// WebSocket callback handler types
type WsOnOpenHandler = (wsId: bigint, protocolPtr: number, protocolLen: number) => void;
type WsOnMessageHandler = (wsId: bigint, dataPtr: number, dataLen: number, isBinary: number) => void;
type WsOnErrorHandler = (wsId: bigint, msgPtr: number, msgLen: number) => void;
type WsOnCloseHandler = (wsId: bigint, code: number, reasonPtr: number, reasonLen: number, wasClean: number) => void;

export const jsz = new ZigJS();

// Temporary buffer for reading back references from storeValue
const tempRefBuffer = new ArrayBuffer(8);
const tempRefView = new DataView(tempRefBuffer);

/** Store a value using jsz.storeValue and get the 64-bit reference. */
export function storeValueGetRef(val: any): bigint {
    const originalMemory = jsz.memory;
    jsz.memory = { buffer: tempRefBuffer } as WebAssembly.Memory;
    jsz.storeValue(0, val);
    jsz.memory = originalMemory;
    return tempRefView.getBigUint64(0, true);
}

/** Shared encoder/decoder — avoids allocating new instances on every call. */
const textDecoder = new TextDecoder();
const textEncoder = new TextEncoder();

/** Cached Uint8Array view of WASM memory. Invalidated when the buffer grows. */
let memoryView: Uint8Array | null = null;
let memoryBuffer: ArrayBufferLike | null = null;

function getMemoryView(): Uint8Array {
    const buf = jsz.memory!.buffer;
    if (buf !== memoryBuffer) {
        memoryBuffer = buf;
        memoryView = new Uint8Array(buf);
    }
    return memoryView!;
}

/**
 * Cache for WASM string reads keyed by (ptr, len).
 * Attribute names / tag names are Zig string literals whose pointers are
 * stable for the lifetime of the module, so caching avoids repeated
 * TextDecoder.decode calls for the same pointer+length pair.
 */
const stringCache = new Map<number, string>();
function stringCacheKey(ptr: number, len: number): number { return ptr * 0x10000 + len; }

/** Read a string from WASM memory */
function readString(ptr: number, len: number): string {
    const key = stringCacheKey(ptr, len);
    const cached = stringCache.get(key);
    if (cached !== undefined) return cached;
    const str = textDecoder.decode(getMemoryView().subarray(ptr, ptr + len));
    stringCache.set(key, str);
    return str;
}

/** Write bytes to WASM memory at a specific location */
function writeBytes(ptr: number, data: Uint8Array): void {
    getMemoryView().set(data, ptr);
}

/** ZX Bridge - provides JS APIs that callback into WASM */
export class ZxBridge {
    #intervals: Map<bigint, number> = new Map();
    #websockets: Map<bigint, WebSocket> = new Map();

    // Cached export lookups — resolved once in the constructor.
    readonly #alloc: (size: number) => number;
    readonly #handler: CallbackHandler | undefined;
    readonly #fetchCompleteHandler: FetchCompleteHandler;
    readonly #wsOnOpenHandler: WsOnOpenHandler | undefined;
    readonly #wsOnMessageHandler: WsOnMessageHandler | undefined;
    readonly #wsOnErrorHandler: WsOnErrorHandler | undefined;
    readonly #wsOnCloseHandler: WsOnCloseHandler | undefined;

    constructor(exports: WebAssembly.Exports) {
        this.#alloc = exports.__zx_alloc as (size: number) => number;
        this.#handler = exports.__zx_cb as CallbackHandler | undefined;
        this.#fetchCompleteHandler = exports.__zx_fetch_complete as FetchCompleteHandler;
        this.#wsOnOpenHandler = exports.__zx_ws_onopen as WsOnOpenHandler | undefined;
        this.#wsOnMessageHandler = exports.__zx_ws_onmessage as WsOnMessageHandler | undefined;
        this.#wsOnErrorHandler = exports.__zx_ws_onerror as WsOnErrorHandler | undefined;
        this.#wsOnCloseHandler = exports.__zx_ws_onclose as WsOnCloseHandler | undefined;
        this.#eventbridge = exports.__zx_eventbridge as ((velementId: bigint, eventTypeId: number, eventRef: bigint) => void) | undefined;
    }

    /** Invoke the unified callback handler */
    #invoke(type: CallbackTypeValue, id: bigint, data: any): void {
        const handler = this.#handler;
        if (!handler) {
            console.warn('__zx_cb not exported from WASM');
            return;
        }
        const dataRef = storeValueGetRef(data);
        handler(type, id, dataRef);
    }

    /**
     * Async fetch with full options support.
     * Calls __zx_fetch_complete when done.
     */
    fetchAsync(
        urlPtr: number,
        urlLen: number,
        methodPtr: number,
        methodLen: number,
        headersPtr: number,
        headersLen: number,
        bodyPtr: number,
        bodyLen: number,
        timeoutMs: number,
        fetchId: bigint
    ): void {
        const url = readString(urlPtr, urlLen);
        const method = methodLen > 0 ? readString(methodPtr, methodLen) : 'GET';
        const headersJson = headersLen > 0 ? readString(headersPtr, headersLen) : '{}';
        const body = bodyLen > 0 ? readString(bodyPtr, bodyLen) : undefined;

        // Parse headers from JSON
        let headers: Record<string, string> = {};
        try {
            headers = JSON.parse(headersJson);
        } catch {
            // Fallback: try line-based format "name:value\n"
            for (const line of headersJson.split('\n')) {
                const colonIdx = line.indexOf(':');
                if (colonIdx > 0) {
                    headers[line.slice(0, colonIdx)] = line.slice(colonIdx + 1);
                }
            }
        }

        const controller = new AbortController();
        const timeout = timeoutMs > 0 ? setTimeout(() => controller.abort(), timeoutMs) : null;

        const fetchOptions: RequestInit = {
            method,
            headers: Object.keys(headers).length > 0 ? headers : undefined,
            body: method !== 'GET' && method !== 'HEAD' ? body : undefined,
            signal: controller.signal,
        };

        fetch(url, fetchOptions)
            .then(async (response) => {
                if (timeout) clearTimeout(timeout);
                const text = await response.text();
                this.#notifyFetchComplete(fetchId, response.status, text, false);
            })
            .catch((error) => {
                if (timeout) clearTimeout(timeout);
                const isAbort = error.name === 'AbortError';
                const errorMsg = isAbort ? 'Request timeout' : (error.message ?? 'Fetch failed');
                this.#notifyFetchComplete(fetchId, 0, errorMsg, true);
            });
    }

    /** Notify WASM that a fetch completed */
    #notifyFetchComplete(fetchId: bigint, statusCode: number, body: string, isError: boolean): void {
        const handler = this.#fetchCompleteHandler;

        // Write the body to WASM memory
        const encoded = textEncoder.encode(body);
        
        // Allocate memory for body
        const ptr = this.#alloc(encoded.length);

        writeBytes(ptr, encoded);
        
        handler(fetchId, statusCode, ptr, encoded.length, isError ? 1 : 0);
    }

    /** Set a timeout and callback when it fires */
    setTimeout(callbackId: bigint, delayMs: number): void {
        setTimeout(() => {
            this.#invoke(CallbackType.Timeout, callbackId, null);
        }, delayMs);
    }

    /** Set an interval and callback each time it fires */
    setInterval(callbackId: bigint, intervalMs: number): void {
        const handle = setInterval(() => {
            this.#invoke(CallbackType.Interval, callbackId, null);
        }, intervalMs) as unknown as number;
        
        this.#intervals.set(callbackId, handle);
    }

    /** Clear an interval */
    clearInterval(callbackId: bigint): void {
        const handle = this.#intervals.get(callbackId);
        if (handle !== undefined) {
            clearInterval(handle);
            this.#intervals.delete(callbackId);
        }
    }

    // ========================================================================
    // WebSocket API
    // ========================================================================

    /**
     * Create and connect a WebSocket.
     * Calls __zx_ws_onopen, __zx_ws_onmessage, __zx_ws_onerror, __zx_ws_onclose.
     */
    wsConnect(
        wsId: bigint,
        urlPtr: number,
        urlLen: number,
        protocolsPtr: number,
        protocolsLen: number
    ): void {
        const url = readString(urlPtr, urlLen);
        const protocolsStr = protocolsLen > 0 ? readString(protocolsPtr, protocolsLen) : '';
        const protocols = protocolsStr ? protocolsStr.split(',').map(p => p.trim()).filter(Boolean) : undefined;

        try {
            const ws = protocols && protocols.length > 0 
                ? new WebSocket(url, protocols)
                : new WebSocket(url);

            ws.binaryType = 'arraybuffer';

            ws.onopen = () => {
                const handler = this.#wsOnOpenHandler;
                if (!handler) return;

                // Write protocol to WASM memory
                const protocol = ws.protocol || '';
                const { ptr, len } = this.#writeStringToWasm(protocol);
                handler(wsId, ptr, len);
            };

            ws.onmessage = (event: MessageEvent) => {
                const handler = this.#wsOnMessageHandler;
                if (!handler) return;

                const isBinary = event.data instanceof ArrayBuffer;
                let data: Uint8Array;

                if (isBinary) {
                    data = new Uint8Array(event.data as ArrayBuffer);
                } else {
                    data = textEncoder.encode(event.data as string);
                }

                const { ptr, len } = this.#writeBytesToWasm(data);
                handler(wsId, ptr, len, isBinary ? 1 : 0);
            };

            ws.onerror = (event: Event) => {
                const handler = this.#wsOnErrorHandler;
                if (!handler) return;

                const msg = 'WebSocket error';
                const { ptr, len } = this.#writeStringToWasm(msg);
                handler(wsId, ptr, len);
            };

            ws.onclose = (event: CloseEvent) => {
                const handler = this.#wsOnCloseHandler;
                if (!handler) return;

                const reason = event.reason || '';
                const { ptr, len } = this.#writeStringToWasm(reason);
                handler(wsId, event.code, ptr, len, event.wasClean ? 1 : 0);

                // Clean up
                this.#websockets.delete(wsId);
            };

            this.#websockets.set(wsId, ws);
        } catch (error) {
            // Connection failed immediately
            const handler = this.#wsOnErrorHandler;
            if (handler) {
                const msg = error instanceof Error ? error.message : 'WebSocket connection failed';
                const { ptr, len } = this.#writeStringToWasm(msg);
                handler(wsId, ptr, len);
            }
        }
    }

    /** Send data over WebSocket */
    wsSend(wsId: bigint, dataPtr: number, dataLen: number, isBinary: number): void {
        const ws = this.#websockets.get(wsId);
        if (!ws || ws.readyState !== WebSocket.OPEN) return;

        const memory = getMemoryView();

        if (isBinary) {
            // WebSocket.send needs an owned copy — WASM memory may be reused.
            ws.send(memory.slice(dataPtr, dataPtr + dataLen));
        } else {
            ws.send(textDecoder.decode(memory.subarray(dataPtr, dataPtr + dataLen)));
        }
    }

    /** Close WebSocket connection */
    wsClose(wsId: bigint, code: number, reasonPtr: number, reasonLen: number): void {
        const ws = this.#websockets.get(wsId);
        if (!ws) return;

        const reason = reasonLen > 0 ? readString(reasonPtr, reasonLen) : undefined;

        try {
            if (reason) {
                ws.close(code, reason);
            } else {
                ws.close(code);
            }
        } catch {
            // Invalid code or reason, just force close
            ws.close();
        }
    }

    /** Write a string to WASM memory, returning pointer and length */
    #writeStringToWasm(str: string): { ptr: number; len: number } {
        const encoded = textEncoder.encode(str);
        return this.#writeBytesToWasm(encoded);
    }

    #writeBytesToWasm(data: Uint8Array): { ptr: number; len: number } {
        const ptr = this.#alloc(data.length);
        writeBytes(ptr, data);
        return { ptr, len: data.length };
    }

    readonly #eventbridge: ((velementId: bigint, eventTypeId: number, eventRef: bigint) => void) | undefined;

    /** Handle a DOM event (called by event delegation) */
    eventbridge(velementId: bigint, eventTypeId: number, event: Event): void {
        if (!this.#eventbridge) return;
        const eventRef = storeValueGetRef(event);
        this.#eventbridge(velementId, eventTypeId, eventRef);
    }

    /** Create the import object for WASM instantiation */
    static createImportObject(bridgeRef: { current: ZxBridge | null }): WebAssembly.Imports {
        return {
            ...jsz.importObject(),
            __zx: {
                // Async fetch with full options
                _fetchAsync: (
                    urlPtr: number,
                    urlLen: number,
                    methodPtr: number,
                    methodLen: number,
                    headersPtr: number,
                    headersLen: number,
                    bodyPtr: number,
                    bodyLen: number,
                    timeoutMs: number,
                    fetchId: bigint
                ) => {
                    bridgeRef.current?.fetchAsync(
                        urlPtr, urlLen,
                        methodPtr, methodLen,
                        headersPtr, headersLen,
                        bodyPtr, bodyLen,
                        timeoutMs,
                        fetchId
                    );
                },
                _setTimeout: (callbackId: bigint, delayMs: number) => {
                    bridgeRef.current?.setTimeout(callbackId, delayMs);
                },
                _setInterval: (callbackId: bigint, intervalMs: number) => {
                    bridgeRef.current?.setInterval(callbackId, intervalMs);
                },
                _clearInterval: (callbackId: bigint) => {
                    bridgeRef.current?.clearInterval(callbackId);
                },
                // WebSocket API
                _wsConnect: (
                    wsId: bigint,
                    urlPtr: number,
                    urlLen: number,
                    protocolsPtr: number,
                    protocolsLen: number
                ) => {
                    bridgeRef.current?.wsConnect(wsId, urlPtr, urlLen, protocolsPtr, protocolsLen);
                },
                _wsSend: (wsId: bigint, dataPtr: number, dataLen: number, isBinary: number) => {
                    bridgeRef.current?.wsSend(wsId, dataPtr, dataLen, isBinary);
                },
                _wsClose: (wsId: bigint, code: number, reasonPtr: number, reasonLen: number) => {
                    bridgeRef.current?.wsClose(wsId, code, reasonPtr, reasonLen);
                },
                // ── Direct DOM externs (bypass jsz for all hot-path operations) ──────────
                //
                // domNodes is a Map<vnode_id, Node> that mirrors the live DOM tree.
                // All mutations use vnode_ids directly so no jsz table lookups are
                // needed on the hot rendering path.

                _ce: (id: number, vnodeId: bigint): bigint => {
                    const tagName = TAG_NAMES[id] as string;
                    const el = id >= SVG_TAG_START_INDEX
                        ? document.createElementNS('http://www.w3.org/2000/svg', tagName)
                        : document.createElement(tagName);
                    (el as any).__zx_ref = Number(vnodeId);
                    domNodes.set(vnodeId, el);
                    // Also store in jsz so the root HTMLElement can be passed to CommentMarker.
                    return storeValueGetRef(el);
                },

                _ct: (ptr: number, len: number, vnodeId: bigint): bigint => {
                    const text = readString(ptr, len);
                    const node = document.createTextNode(text);
                    (node as any).__zx_ref = Number(vnodeId);
                    domNodes.set(vnodeId, node);
                    return storeValueGetRef(node);
                },

                _sa: (vnodeId: bigint, namePtr: number, nameLen: number, valPtr: number, valLen: number) => {
                    (domNodes.get(vnodeId) as Element | undefined)
                        ?.setAttribute(readString(namePtr, nameLen), readString(valPtr, valLen));
                },

                _ra: (vnodeId: bigint, namePtr: number, nameLen: number) => {
                    (domNodes.get(vnodeId) as Element | undefined)
                        ?.removeAttribute(readString(namePtr, nameLen));
                },

                _snv: (vnodeId: bigint, ptr: number, len: number) => {
                    const node = domNodes.get(vnodeId);
                    if (node) node.nodeValue = readString(ptr, len);
                },

                _ac: (parentId: bigint, childId: bigint) => {
                    const parent = domNodes.get(parentId);
                    const child = domNodes.get(childId);
                    if (parent && child) parent.appendChild(child);
                },

                _ib: (parentId: bigint, childId: bigint, refId: bigint) => {
                    const parent = domNodes.get(parentId);
                    const child = domNodes.get(childId);
                    const ref = domNodes.get(refId) ?? null;
                    if (parent && child) parent.insertBefore(child, ref);
                },

                _rc: (parentId: bigint, childId: bigint) => {
                    const parent = domNodes.get(parentId);
                    const child = domNodes.get(childId);
                    if (parent && child) {
                        parent.removeChild(child);
                        cleanupDomNodes(child);
                    }
                },

                _rpc: (parentId: bigint, newId: bigint, oldId: bigint) => {
                    const parent = domNodes.get(parentId);
                    const newChild = domNodes.get(newId);
                    const oldChild = domNodes.get(oldId);
                    if (parent && newChild && oldChild) {
                        parent.replaceChild(newChild, oldChild);
                        cleanupDomNodes(oldChild);
                    }
                },
            },
        };
    }
}

/** JS-side DOM node registry: vnode_id → Node. Mirrors the live DOM tree. */
const domNodes = new Map<bigint, Node>();

/** Recursively remove a node subtree from domNodes. */
function cleanupDomNodes(node: Node): void {
    const ref = (node as any).__zx_ref;
    if (ref !== undefined) domNodes.delete(BigInt(ref));
    const children = node.childNodes;
    for (let i = 0; i < children.length; i++) cleanupDomNodes(children[i]!);
}

// Index where SVG tags start in TAG_NAMES array
const SVG_TAG_START_INDEX = 140;

// Event delegation constants
const TAG_NAMES = [
    'aside',
    'fragment',
    'iframe',
    'slot',
    'img',
    'html',
    'base',
    'head',
    'link',
    'meta',
    'script',
    'style',
    'title',
    'address',
    'article',
    'body',
    'h1',
    'h6',
    'footer',
    'header',
    'h2',
    'h3',
    'h4',
    'h5',
    'hgroup',
    'nav',
    'section',
    'dd',
    'dl',
    'dt',
    'div',
    'figcaption',
    'figure',
    'hr',
    'li',
    'ol',
    'ul',
    'menu',
    'main',
    'p',
    'picture',
    'pre',
    'a',
    'abbr',
    'b',
    'bdi',
    'bdo',
    'br',
    'cite',
    'code',
    'data',
    'time',
    'dfn',
    'em',
    'i',
    'kbd',
    'mark',
    'q',
    'blockquote',
    'rp',
    'ruby',
    'rt',
    'rtc',
    'rb',
    's',
    'del',
    'ins',
    'samp',
    'small',
    'span',
    'strong',
    'sub',
    'sup',
    'u',
    'var',
    'wbr',
    'area',
    'map',
    'audio',
    'source',
    'track',
    'video',
    'embed',
    'object',
    'param',
    'canvas',
    'noscript',
    'caption',
    'table',
    'col',
    'colgroup',
    'tbody',
    'tr',
    'thead',
    'tfoot',
    'td',
    'th',
    'button',
    'datalist',
    'option',
    'fieldset',
    'label',
    'form',
    'input',
    'keygen',
    'legend',
    'meter',
    'optgroup',
    'select',
    'output',
    'progress',
    'textarea',
    'details',
    'dialog',
    'menuitem',
    'summary',
    'content',
    'element',
    'shadow',
    'template',
    'acronym',
    'applet',
    'basefont',
    'font',
    'big',
    'blink',
    'center',
    'command',
    'dir',
    'frame',
    'frameset',
    'isindex',
    'listing',
    'marquee',
    'noembed',
    'plaintext',
    'spacer',
    'strike',
    'tt',
    'xmp',
    // SVG Tags
    'animate',
    'animateMotion',
    'animateTransform',
    'circle',
    'clipPath',
    'defs',
    'desc',
    'ellipse',
    'feBlend',
    'feColorMatrix',
    'feComponentTransfer',
    'feComposite',
    'feConvolveMatrix',
    'feDiffuseLighting',
    'feDisplacementMap',
    'feDistantLight',
    'feDropShadow',
    'feFlood',
    'feFuncA',
    'feFuncB',
    'feFuncG',
    'feFuncR',
    'feGaussianBlur',
    'feImage',
    'feMerge',
    'feMergeNode',
    'feMorphology',
    'feOffset',
    'fePointLight',
    'feSpecularLighting',
    'feSpotLight',
    'feTile',
    'feTurbulence',
    'filter',
    'foreignObject',
    'g',
    'image',
    'line',
    'linearGradient',
    'marker',
    'mask',
    'metadata',
    'mpath',
    'path',
    'pattern',
    'polygon',
    'polyline',
    'radialGradient',
    'rect',
    'set',
    'stop',
    'svg',
    'switch',
    'symbol',
    'text',
    'textPath',
    'tspan',
    'use',
    'view',
] as const;



const DELEGATED_EVENTS = [
    'click', 'dblclick',
    'input', 'change', 'submit',
    'focus', 'blur',
    'keydown', 'keyup', 'keypress',
    'mouseenter', 'mouseleave',
    'mousedown', 'mouseup', 'mousemove',
    'touchstart', 'touchend', 'touchmove',
    'scroll',
] as const;

type DelegatedEvent = typeof DELEGATED_EVENTS[number];

const EVENT_TYPE_MAP: Record<DelegatedEvent, number> = {
    'click': 0, 'dblclick': 1, 'input': 2, 'change': 3, 'submit': 4,
    'focus': 5, 'blur': 6, 'keydown': 7, 'keyup': 8, 'keypress': 9,
    'mouseenter': 10, 'mouseleave': 11, 'mousedown': 12, 'mouseup': 13,
    'mousemove': 14, 'touchstart': 15, 'touchend': 16, 'touchmove': 17,
    'scroll': 18,
};

/** Initialize event delegation */
export function initEventDelegation(bridge: ZxBridge, rootSelector: string = 'body'): void {
    const root = document.querySelector(rootSelector);
    if (!root) return;

    for (const eventType of DELEGATED_EVENTS) {
        root.addEventListener(eventType, (event: Event) => {
            let target = event.target as HTMLElement | null;

            while (target && target !== document.body) {
                const zxRef = (target as any).__zx_ref;
                if (zxRef !== undefined) {
                    bridge.eventbridge(BigInt(zxRef), EVENT_TYPE_MAP[eventType] ?? 0, event);
                    if (event.cancelBubble) break;
                }
                target = target.parentElement;
            }
        }, { passive: eventType.startsWith('touch') || eventType === 'scroll' });
    }
}

export type InitOptions = {
    url?: string;
    eventDelegationRoot?: string;
    importObject?: WebAssembly.Imports;
};

const DEFAULT_URL = "/assets/main.wasm";

/** Initialize WASM with the ZX Bridge */
export async function init(options: InitOptions = {}): Promise<{ source: WebAssembly.WebAssemblyInstantiatedSource; bridge: ZxBridge }> {
    const url = options.url ?? DEFAULT_URL;
    
    // Bridge reference for import object (will be set after instantiation)
    const bridgeRef: { current: ZxBridge | null } = { current: null };
    
    const importObject = Object.assign(
        {},
        ZxBridge.createImportObject(bridgeRef),
        options.importObject
    );
    
    const source = await WebAssembly.instantiateStreaming(fetch(url), importObject);
    const { instance } = source;

    jsz.memory = instance.exports.memory as WebAssembly.Memory;
    
    const bridge = new ZxBridge(instance.exports);
    bridgeRef.current = bridge;

    initEventDelegation(bridge, options.eventDelegationRoot ?? 'body');

    // Call main to initiate the client side rendering
    const main = instance.exports.mainClient;
    if (typeof main === 'function') main();

    return { source, bridge };
}

// Global type declarations
declare global {
    interface HTMLElement {
        __zx_ref?: number;
    }
}
