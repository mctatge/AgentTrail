# License and dependency notices

AgentTrail source is provided under the [MIT license](LICENSE). Keep that notice when redistributing substantial portions of the software. The app-packaging script includes the license and these notices in the app's Resources directory.

## Runtime/build components

| Component | How it is used | Licensing boundary |
| --- | --- | --- |
| Swift standard library and Apple SDK frameworks | Compiled against the developer's installed toolchain; AppKit, SwiftUI, Core Graphics, Accessibility, Carbon, ScreenCaptureKit, Foundation, and Combine | Supplied by Apple/toolchain; SDK and distribution terms remain applicable. AgentTrail does not relicense the SDKs or vendor their source. |
| SQLite | System library, linked through a two-file C module shim | SQLite's authors dedicate its deliverable code to the public domain; see [SQLite copyright](https://www.sqlite.org/copyright.html). No SQLite source is vendored here. |
| Python standard library | Local/CI validation scripts | Supplied by the developer or CI runtime; no Python packages are downloaded by these scripts. |
| GitHub Actions checkout | CI checkout only, pinned to a verified commit | External CI action, not embedded in the app; see [its MIT license](https://github.com/actions/checkout/blob/main/LICENSE). |

`Package.swift` has no external Swift package dependencies. The publication review found no vendored third-party implementation or copied third-party assets in the source tree. Related projects linked from the README are comparisons, not dependencies or endorsements; their licenses do not apply to this independent implementation merely because they are linked.

The software license does not license recorded data or guarantee ownership, originality, copyrightability, trademark clearance, or patent clearance. Copyright protection for machine-generated portions can depend on applicable law and human authorship; see the [U.S. Copyright Office's AI materials](https://www.copyright.gov/ai/). These notices are not a legal opinion or an assertion of exclusive rights in every generated line.

Product names referenced for interoperability remain associated with their respective owners. No affiliation with or endorsement by Apple, Microsoft, AI-client providers, or the linked projects is implied.
