# Profile-scoped connectors

AI Settings manages OAuth connectors for one browser Profile at a time. The
selected local Chromium Profile ID is sent as `profile_id` when listing,
authorizing, or deleting a Profile-owned connection.

For migration, the client requests the explicit `all_profiles=true` management
scope once, then locally separates the selected Profile's connections from rows
whose `profile_id` is absent. Unassigned connections are shown as connected but
not assigned, with an **Assign** action. Assign calls
`PATCH /api/auth/oauth/connections/:provider` with the selected Profile ID and
reuses the existing OAuth credentials. The single request also prevents two
concurrent refresh attempts against a compatibility-default connection that has
already been assigned to the selected Profile.

A compatibility response whose connection already has a `profile_id` is not
shown as unassigned. This lets Core keep the connection available to older
clients without leaking it into another Profile's settings state.

The Connectors enablement switch is application-wide. Turning it off calls
Core's transactional current-user disconnect endpoint, which removes every
OAuth credential across all browser Profiles and the legacy unassigned
connection, invalidates pending OAuth authorization states, and prevents an
in-flight callback from restoring a credential after disconnect completes.
