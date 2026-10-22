# Notification agent avatar regression

Run `bash build-scripts/test-agent-avatar.sh` on macOS with Xcode installed.
The harness compiles the production avatar download methods and SwiftUI avatar
view, substituting only metadata/service dependencies. An intercepted external
URL checks that no Phi bearer header is sent. It uses no account or private files.

Coverage: relative and historical loopback file references, encoded paths and
queries, unrelated origins, data URLs, visible local fallback, image decoding,
and network/HTTP failure fallback. SwiftUI ImageRenderer checks the actual
fallback pixels. Service routing is asserted at the APIClient delegation boundary;
this does not establish Broker socket or loopback HTTP integration. The existing
PhiAgentTransportTests cover those transports in the application-hosted suite.
