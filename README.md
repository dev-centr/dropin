<a id="readme-top"></a>
<div align="center">
  <a href="https://github.com/dev-centr/dropin/graphs/contributors"><img src="https://img.shields.io/github/contributors/dev-centr/dropin.svg?style=for-the-badge" alt="Contributors"></a>
  <a href="https://github.com/dev-centr/dropin/network/members"><img src="https://img.shields.io/github/forks/dev-centr/dropin.svg?style=for-the-badge" alt="Forks"></a>
  <a href="https://github.com/dev-centr/dropin/stargazers"><img src="https://img.shields.io/github/stars/dev-centr/dropin.svg?style=for-the-badge" alt="Stargazers"></a>
  <a href="https://github.com/dev-centr/dropin/issues"><img src="https://img.shields.io/github/issues/dev-centr/dropin.svg?style=for-the-badge" alt="Issues"></a>
  <a href="https://github.com/dev-centr/dropin/blob/main/LICENSE"><img src="https://img.shields.io/github/license/dev-centr/dropin.svg?style=for-the-badge" alt="License"></a>

  <h3 align="center">dropin</h3>

  <p align="center">
    Resident engine, CLI, and MCP for driving an app from outside its window.
    <br />
    <a href="https://docs.devcentr.org/platforms/specifications/components/dropin/"><strong>Explore the docs »</strong></a>
    <br />
    <br />
    <a href="https://github.com/dev-centr/dropin/issues">Report Bug</a>
    &middot;
    <a href="https://github.com/dev-centr/dropin/issues">Request Feature</a>
  </p>
</div>

<details>
  <summary>Contents</summary>
  <ol>
    <li><a href="#about">About</a></li>
    <li><a href="#built-with">Built with</a></li>
    <li><a href="#install">Install</a></li>
    <li><a href="#use">Use</a></li>
    <li><a href="#mcp">MCP</a></li>
    <li><a href="#memory">Memory</a></li>
    <li><a href="#changelog">Changelog</a></li>
    <li><a href="#license">License</a></li>
    <li><a href="#contact">Contact</a></li>
  </ol>
</details>

## About

<a id="about"></a>

`dropin` is the control process other programs can share. A CLI or an MCP client only appends a request. One resident engine consumes the queue. A newer build of that engine can take the same session while the old process finishes the request it already started.

Task lists are a separate file, `tasks.sdl`. A window watches that file and redraws when it changes. DevCentr's **Tasks** page is the first watcher. The same session can be used from another product without linking its UI into this repository.

The ring protocol, plugin ABI, and handoff rules are in [`docs/spec.adoc`](docs/spec.adoc).

<p align="right"><a href="#readme-top">back to top</a></p>

## Built with

<a id="built-with"></a>

**Runtime**

- [D](https://dlang.org/)
- [Dub](https://dub.pm/)
- [LDC](https://github.com/ldc-developers/ldc) when DMD is not installed

**Protocol**

- A file-backed memory map and atomics. No garbage-collected objects in the ring.

<p align="right"><a href="#readme-top">back to top</a></p>

## Install

<a id="install"></a>

From a checkout:

```shell
dub build --compiler=ldc2
```

The executable is `dropin`. A later DUB release will be the install path. This tree is not published yet.

<p align="right"><a href="#readme-top">back to top</a></p>

## Use

<a id="use"></a>

```shell
dropin --session devcentr engine
dropin --session devcentr call ping
dropin --session devcentr tasks write tasks.sdl
dropin --session devcentr handoff C:\path\to\new-dropin.exe
```

`--json` prints one JSON object. Failures print the reason on the console. The session log is `engine.log` next to the ring. `--no-spawn` refuses to start an engine for a call that needs one.

The default session is `devcentr` so the DevCentr window and this tool meet. Override it with `--session` or `DROPIN_SESSION`. `DROPIN_HOME` moves the whole session directory.

<p align="right"><a href="#readme-top">back to top</a></p>

## MCP

<a id="mcp"></a>

```json
{
  "mcpServers": {
    "devcentr": {
      "command": "dropin",
      "args": ["--session", "devcentr", "mcp"]
    }
  }
}
```

Tools: `dropin_status`, `dropin_tasks_read`, `dropin_tasks_write`, `dropin_call`, `dropin_plugin_reload`, `dropin_shutdown`.

<p align="right"><a href="#readme-top">back to top</a></p>

## Memory

<a id="memory"></a>

The ring is raw bytes. Callers may use the default GC, [tgc](https://code.dlang.org/packages/tgc), or `@nogc`. Do not put D pointers in the map. A plugin is its own shared library and may pick a different collector than the engine. State that must survive a reload belongs in `tasks.sdl` or the ring.

D has no maintained resident hot-swap engine to reuse. `reloaded` restarts a process. `conduit` is POSIX-only shared memory. The unfinished `std.ipc` proposal never landed. This tree is the small host those sketches describe, with Windows included and the collector left to the plugin.

<p align="right"><a href="#readme-top">back to top</a></p>

## Changelog

<a id="changelog"></a>

See [CHANGELOG.adoc](CHANGELOG.adoc).

<p align="right"><a href="#readme-top">back to top</a></p>

## License

<a id="license"></a>

MIT. See [LICENSE](LICENSE).

<p align="right"><a href="#readme-top">back to top</a></p>

## Contact

<a id="contact"></a>

Dev-Centr — https://github.com/dev-centr/dropin

<p align="right"><a href="#readme-top">back to top</a></p>
