# Phi Browser

Phi Browser is a Chromium-based AI browser for macOS, built as a native app with AppKit and SwiftUI.

This repository contains the macOS client source code. To build the app locally, you will need Xcode 26 or later and a local copy of `Phi Framework.framework`.

## Build

### Requirements

- Mac with Apple chip
- Xcode 26+
- A local copy of `Phi Framework.framework`

### Build Steps

1. Check out this repository.
2. Download the latest release of `Phi Framework` from the [phibrowser/phibrowser-framework](https://github.com/phibrowser/phibrowser-framework/releases) repository.
3. Place `Phi Framework.framework` into the root `Frameworks/` directory of this repository.
4. Open `Phi.xcodeproj` in Xcode and wait for Swift Package Manager to resolve dependencies.
5. Select PhiBrowser-canary scheme.
6. Build and run the app, then start your Phi Browser journey.

## Contributing

Contributions are welcome.

If you find a bug, have an idea for improvement, or want to propose a new feature, please open an issue first. If you would like to contribute code, feel free to submit a pull request with a clear description of the change and the motivation behind it.

We welcome:

- bug reports
- feature requests
- documentation improvements
- pull requests

## License

Phi Browser is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.
