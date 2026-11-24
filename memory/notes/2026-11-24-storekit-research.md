# StoreKit: what Apple's documentation says (read 2026-11-24)

Research for `plans/2026-11-24-account-and-subscription.md`, read through sosumi. "Not found" means Apple's pages did not say; test it before relying on it.

## Testing locally

- A `.storekit` configuration file is activated in two documented ways: the scheme's Run option (Edit Scheme > Run > Options > StoreKit Configuration), and the StoreKitTest framework for automated tests.
- **Not found:** whether an app installed and launched with `simctl` or XcodeBuildMCP sees the configuration. Assume it does not until an experiment shows otherwise; screenshots and hand checks need a DEBUG launch argument that sets the subscription state.
- `SKTestSession(configurationFileNamed:)` wants the file in the application's bundle; `SKTestSession(contentsOf: URL)` takes any `.storekit` file URL. Whether a file only in the test bundle works with the first one: not found. Use `contentsOf:` with the test bundle's URL.
- "There's a single instance of the test environment": tests that use a session must run serially (`.serialized` suite).
- Session controls: `buyProduct(identifier:options:)` (returns a StoreKit 2 `Transaction`), `expireSubscription(productIdentifier:)`, `forceRenewalOfSubscription`, `refundTransaction(identifier:)`, `shouldEnterBillingRetryOnRenewal`, `billingGracePeriodIsEnabled` (default false), `resolveIssueForTransaction`, `timeRate`, `disableDialogs`, `clearTransactions()`, `resetToDefaultState()`, `setSimulatedError(_:forAPI:)`, ask-to-buy controls. There is no separate revoke method.
- Nothing documented about `xcodebuild test` or Swift Testing with StoreKitTest: the first task must prove it runs here.
- XcodeGen 2.46.0: a `.storekit` file under a target's `sources` goes to the resources phase by default (it would ship in the app); use `buildPhase: none` to keep it out of the app, and list it under `SeasignTests` sources to put it in the test bundle. `targets.Seasign.scheme.storeKitConfiguration: <path relative to ios/>` sets it for the Run action only; there is no key for the test action.

## Subscription states

`Product.SubscriptionInfo.RenewalState` (a struct, so a `switch` needs a `default`):

| case | Apple's meaning | Seasign state |
|---|---|---|
| `subscribed` | the customer is currently subscribed | Subscribed |
| `inGracePeriod` | billing grace period | Lapsed (the user, 2026-11-24: stop as soon as a renewal fails). Grace period is opt-in in App Store Connect and stays off |
| `inBillingRetryPeriod` | Apple is retrying a failed payment | Lapsed |
| `expired` | the subscription expired | Lapsed |
| `revoked` | the App Store revoked access (refund and the like) | Lapsed |
| anything else | unknown to this build | not Subscribed (AI off) |

- Apple: "Subscriptions in the subscribed and inGracePeriod states are entitled to service."
- `Transaction.currentEntitlements` is what Apple points to for unlocking content; it yields the latest transaction of each subscription that is subscribed or in grace period, and leaves out refunded or revoked ones. It does not throw, so "empty" and "could not answer" look the same; `Product.SubscriptionInfo.status` is `async throws`. Offline behaviour: not found. Free versus Lapsed needs the status call (or the transaction history), since both have no current entitlement.
- `appAccountToken` is a `UUID` passed as `Product.PurchaseOption.appAccountToken(_:)`; the server sees it in the decoded transaction and renewal info.
- Restore: "Include some mechanism in your app, such as a Restore Purchases button"; `AppStore.sync()` only on an explicit user action (it shows an App Store sign-in prompt).

## Server side (phase B, not decided)

- Apple's signed data is a JWS with an `x5c` certificate chain (leaf, Apple intermediate with OID 1.2.840.113635.100.6.2.1, Apple root). Apple gives no full validation checklist; validating the chain in a Worker means X.509 parsing (a library, which is ask-first, or hand-written code).
- The alternative: App Store Server API, Get All Subscription Statuses, `GET https://api.storekit.apple.com/inApps/v1/subscriptions/{transactionId}` (sandbox host `api.storekit-sandbox.apple.com`), with a bearer JWT signed ES256 by an In-App Purchase key from App Store Connect (`kid`, `iss` issuer ID, `aud: appstoreconnect-v1`, `bid`). Status: 1 active, 2 expired, 3 billing retry, 4 grace period, 5 revoked. The status comes over TLS from Apple, so no certificate parsing is needed to trust it; `appAccountToken` and the product ID are inside `signedTransactionInfo`, which still has to be base64url-decoded. This needs a secret the user sets and cannot be exercised with Xcode-environment transactions (those are signed by Xcode); it is a sandbox check after the deploy.
