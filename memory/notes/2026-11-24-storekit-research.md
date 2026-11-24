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

## Experiments run in task 215 (2026-11-24, Xcode 27.2)

**1. `SKTestSession` under `xcodebuild test` works** on both runtimes (iPhone 17 iOS 27.2, iPhone 16 iOS 18.3.1), in the app-hosted Swift Testing bundle, in a `.serialized` suite. The file is `ios/SeasignTests/Subscription/Seasign.storekit` (hand-written JSON, version 4.0: one subscription group, one `RecurringSubscription`, `P1M`, `2.99`, no introductory offer), in the test bundle only. It is found with `Bundle(for:)` on a class in the test bundle (`Bundle.main` is the host app) and opened with `SKTestSession(contentsOf:)`. StoreKitTest lives in the simulator SDK's `Developer/Library/Frameworks`; `import StoreKitTest` in the test target is enough, with no project setting and no capability. What was seen:

- `Product.products` returns the one product, `$2.99`, one month.
- `RenewalState` raw values: 1 subscribed, 2 expired, 3 billing retry, 4 grace period, 5 revoked.
- A fresh session's status is `[]`, and `Transaction.latest` is nil: Free.
- After `buyProduct(identifier:options:)` the status is `[1]`. On iOS 18.3 the first read straight after the purchase was still `[]`, so tests poll.
- `refundTransaction(identifier:)` gives `[5]` (revoked); a Transaction update (with `revocationDate`) and a Status update fire.
- A purchase dated 40 days ago with `.purchaseDate(_, renewalBehavior: .cancelImmediately)` gives `[2]` (expired).
- `expireSubscription(productIdentifier:)` is unreliable in-process: once this process has read the group as subscribed, StoreKit goes on answering subscribed (status, `Transaction.currentEntitlements`, `Transaction.latest`, all with the old expiry a month out, still after 15 s), and no Transaction or Status update fires, though the session's own `allTransactions()` shows the new expiration date. It worked only when nothing had read the subscription first. In the suite it failed in 4 of 4 runs even with the app's own listener off, so the expiry test uses the past-dated purchase instead. Whether a real expiry reaches a running app without a relaunch is not known.
- `setSimulatedError(_, forAPI: .subscriptionStatus)` does not make the status call throw: it answers `[]`, which alone looks like Free. Hence the rule: an empty status with any transaction on record (`Transaction.all`) is Unknown, not Free.
- `setSimulatedError(_, forAPI: .loadProducts)` makes `Product.products` throw (27.2: `systemError(unknown)`, 18.3: the URL error given).
- The test environment is one per simulator and outlives the run; tests clear transactions and simulated errors when they start and when they end.

**2. For an app launched with `simctl`, the scheme's StoreKit configuration made no difference. That the app saw the simulator's leftover test environment instead is an inference: no clean simulator was tried.** A temporary Debug probe logged `Product.products(for: [monthly]).count` at launch (iPhone 17, iOS 27.2, `simctl install` + `simctl launch --console-pty`). With `targets.Seasign.scheme.storeKitConfiguration` set: 1. With the key removed and the app rebuilt: also 1. The probe tests had just run on that simulator, so the app saw the test environment `SKTestSession` left there, not the scheme. So the scheme key is not set. Screenshots and hand checks use `-debugSubscription`, and the StoreKit tests leave no transactions behind, since a later `simctl` launch on the same simulator would see them. Not checked: a simulator that never ran `SKTestSession` (no other simulator was touched).
