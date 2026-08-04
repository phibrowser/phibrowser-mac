# Phi Browser

**The open-source AI browser for macOS.** Agentic, local-first, and native Swift.

Phi is a Chromium-based browser built as a real native macOS app (AppKit + SwiftUI), with an AI agent that actually does things, a memory that lives in a file you can read, and AI that can run on-device. It's built for something new: a browser a person and an AI agent can use *together*, in the same window and the same session, each a first-class user. No black box. The whole macOS client is open source, right here.

> **Download** (free, macOS): [phibrowser.com](https://phibrowser.com) · If this is your kind of thing, a ⭐ helps a lot.

<!-- TODO (Alpha): drop a screenshot or short demo gif here. It roughly triples how many visitors star. -->

## What makes it different

- **Humans and agents, in the same browser.** Most tools make you choose: a browser for people, or a headless one for bots. Phi is both at once. A person and an AI agent can work in the same window, the same session, the same tabs, at the same time, each a first-class user instead of the agent being boxed off in a sandbox. CLI-friendly, Playwright-compatible, and MCP support mean your own tools and agents can drive it right alongside you.
- **The agent does the browsing.** Give it a task and watch it click, type, and navigate, with a visible record of every action it took. Not a chat panel bolted onto a browser.
- **Memory you can actually read.** Phi's memory lives locally as files you can open, edit, and delete. It stays on your Mac, and it never trains anyone's model.
- **On-device AI.** Routes through Apple's on-device Foundation Models (and MLX) where it can, so the work happens on your machine, not someone else's server. Bring your own models via Ollama / LM Studio, or switch AI off entirely.
- **Reusable Skills.** Teach the agent a workflow once (built on an open `SKILL.md` standard); it knows it forever, with permissions enforced at runtime rather than promised in a doc.
- **Native, not Electron.** Real AppKit + SwiftUI. Fast, and at home on macOS.

## Why open source

A browser sees everything you do, so you should be able to read the code that runs it. Phi's macOS client is Apache-2.0: audit it, fork it, or just trust it because you can check. (The Chromium framework layer lives separately.)

## Download

Free for macOS on Apple Silicon: [phibrowser.com](https://phibrowser.com)

## Build from source

### Requirements
- Mac with Apple chip
- Xcode 26+
- A local copy of `Phi Framework.framework`

### Steps
1. Check out this repository.
2. Download the latest `Phi Framework` from [phibrowser/phibrowser-framework](https://github.com/phibrowser/phibrowser-framework/releases).
3. Place `Phi Framework.framework` into the root `Frameworks/` directory.
4. Open `Phi.xcodeproj` in Xcode and let Swift Package Manager resolve dependencies.
5. Select the `PhiBrowser-OpenSource` scheme.
6. Build.

## Contributing

Contributions are welcome. Found a bug, have an idea, or want to add a feature? Open an issue first. To contribute code, send a PR with a clear description of the change and the motivation behind it.

We welcome bug reports, feature requests, documentation improvements, and pull requests.

### Translations

Phi ships in 8 languages, currently machine-seeded and waiting for native speakers to make them feel right. If you can read a JSON file, you can help: every user-visible string in the Phi product family lives in [phibrowser/phi-i18n](https://github.com/phibrowser/phi-i18n), each with context on where it appears and what it does. Translations merged there flow into the next Phi build automatically, credited to you. A web UI (Weblate) is on the way for contributors who would rather never see a git command.

## License

Apache License 2.0. See [LICENSE](LICENSE).
