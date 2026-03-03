# Ziex

A full-stack web framework for Zig. Write declarative UI components using familiar JSX patterns, transpiled to efficient Zig code.

Ziex combines the power and performance of Zig with the expressiveness of JSX, enabling you to build fast, type-safe web applications.

**[Documentation →](https://ziex.dev/learn)**

## Installation

##### Linux/macOS
```bash
curl -fsSL https://ziex.dev/install | bash
```

##### Windows
```powershell
powershell -c "irm ziex.dev/install.ps1 | iex"

```
##### Installing Zig
```bash
brew install zig # macOS
winget install -e --id zig.zig # Windows
```
[_See for other platforms →_](https://ziglang.org/learn/getting-started/)

## Quick Example

```tsx site/pages/examples/overview.zx
pub fn QuickExample(allocator: zx.Allocator) zx.Component {
    const is_loading = true;
    const chars = "Hello, Ziex Dev!";
    var i: usize = 0;
    return (
        <main @allocator={allocator}>
            <section>
                {if (is_loading) (<h1>Loading...</h1>) else (<h1>Loaded</h1>)}
            </section>
        
            <section>
                {for (chars) |char| (<span>{char}</span>)}
            </section>
        
            <section>
                {for (users) |user| (
                    <Profile name={user.name} age={user.age} role={user.role} />
                )}
            </section>

            <section>
                {while (i < 10) : (i += 1) (<p>{i}</p>)}
            </section>
        </main>
    );
}

fn Profile(allocator: zx.Allocator, user: User) zx.Component {
    return (
        <div @allocator={allocator}>
            <h1>{user.name}</h1>
            <p>{user.age}</p>
            {switch (user.role) {
                .admin => (<p>Admin</p>),
                .member => (<p>Member</p>),
            }}
        </div>
    );
}

const UserRole = enum { admin, member };
const User = struct { name: []const u8, age: u32, role: UserRole };

const users = [_]User{
    .{ .name = "John", .age = 20, .role = .admin },
    .{ .name = "Jane", .age = 21, .role = .member },
};

const zx = @import("zx");
```
## Feature Checklist

- [x] Server Side Rendering (SSR)
    - [x] Streaming
- [x] Static Site Generation (SSG)
    - [x] `options.static.params`, `options.static.getParams`
- [ ] Client Side Rendering (CSR) via WebAssembly (_Alpha_)
    - [x] Virtual DOM and diffing
    - [x] Rendering only changed nodes
    - [x] `on`event handler
    - [x] State managment
    - [x] Hydration
    - [ ] Lifecycle hook
    - [ ] Server Actions
    - [ ] Rendering performance
- [x] Client Side Rendering (CSR) via React
- [ ] MDZX (Markdown + ZX) (MDX eqiuvalent)
- [ ] Render page as markdown via .md
- [x] Routing
    - [x] File-system Routing
    - [x] Search Parameters
    - [x] Path Segments
- [x] Components
- [x] Control Flow
    - [x] `if`
    - [x] `if/else`
    - [x] `for`
    - [x] `switch`
    - [x] `while`
    - [x] nesting control flows
    - [x] error/optional captures in `while` and `if`
- [x] Assets
    - [x] Copying
    - [x] Serving
- [ ] Assets Optimization
    - [ ] Image
    - [x] CSS (via plugins such as Tailwind)
    - [x] JS/TS (via esbuild)
    - [x] HTML (optimized by default)
- [x] Proxy/Middleware
- [ ] Caching (configurable)
    - [x] Component
    - [ ] Layout
    - [x] Page
    - [ ] Assets
- [x] API Route
    - [x] Websocket Route
- [ ] Plugin (_Alpha_)
    - [x] Builtin TailwindCSS and Esbuild
    - [x] Command based plugin system
    - [ ] Source based plugin system
- [x] Context (configurable)
    - [x] App
    - [x] Layout
    - [x] Page
    - [x] Component
- [x] `error.zx` for default and per-route error page
- [x] `notfound.zx` for default and per-route error page
- [x] CLI
    - [x] `init` Project Template
    - [x] `transpile` Transpile .zx files to Zig source code
    - [x] `serve` Serve the project
    - [x] `dev` HMR or Rebuild on Change
    - [x] `fmt` Format the ZX source code
    - [x] `export` Generate static site assets
    - [x] `bundle` Bundle the ZX executable with public/assets and exe
    - [x] `version` Show the version of the ZX CLI
    - [x] `update` Update the version of ZX dependency
    - [x] `upgrade` Upgrade the version of ZX CLI
- [ ] Platform
    - [x] Server
    - [x] Browser
    - [ ] Edge Runtime (Cloudflare Workers, Vercel Function, etc)
    - [ ] iOS
    - [ ] Android
    - [ ] macOS
    - [ ] Windows

#### Editor Support

- ##### [VSCode](https://marketplace.visualstudio.com/items?itemName=ziex.ziex)/[VSCode Forks](https://open-vsx.org/extension/ziex/ziex) Extension
- ##### [Neovim](/ide/neovim/)
- ##### [Helix](/ide/helix/)
- ##### [Zed](/ide/zed/)

## Community

- [Discord](https://ziex.dev/r/discord)
- [Topic on Ziggit](https://ziex.dev/r/ziggit)
- [Project on Zig Discord Community](https://ziex.dev/r/zig-discord) (Join Zig Discord first: https://discord.gg/zig)

## Similar Projects

- [Ziex VS →](https://ziex.dev/vs)

## Related Projects

* [Codeberg Mirror](https://codeberg.org/nurulhudaapon/ziex) - ZX repository mirror on Codeberg
* [ziex.dev](https://github.com/nurulhudaapon/ziex/tree/main/site) - Official documentation site of ZX made using ZX.
* [example-blog](https://github.com/ziex-dev/example-blog) - Demo blog web application built with ZX
* [zx-numbers-game](https://github.com/Andrew-Velox/zx-numbers-game) - ZX numbers game

## Contributing

Contributions are welcome! Currently trying out ZX and reporting issues for edge cases and providing feedback are greatly appreciated.
