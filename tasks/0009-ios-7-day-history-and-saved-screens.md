---
id: 9
title: iOS: 7-day history and Saved screens
status: done
owner: implementer-2
depends_on: [8]
created: 2026-11-15T22:33:55Z
updated: 2026-11-16T05:05:28Z
---

## Goal

Read plans/2026-11-15-v1-build.md first; it holds the decisions and design. The >> button opens History: every FeedItem from the last 7 days, newest first, with keyword search, a category filter and a save action per item. The asterisk button opens Saved (ref-img/00-save-list.png): keyword search, category filter, notes per item, Remove (SwiftData SavedItem, kept after the feed item is pruned). Both open the reading view on tap.

## Acceptance criteria

- [x] History lists items from the last 7 days and nothing older; search and category filter work
- [x] Saving from History or the reading view adds the item to Saved; notes persist; Remove deletes it
- [x] Simulator screenshots of History and Saved recorded in the task log; Saved resembles ref-img/00-save-list.png
- [x] Tests pass on both simulators

## Relevant files

- ios/Seasign/History/
- ios/Seasign/Saved/
- ios/Seasign/Feed/

## What's been tried

- Typing into the History search field with XcodeBuildMCP type_text did not reach the field (screen unchanged; likely the hardware-keyboard quirk in architecture.md). Search is covered by unit tests instead.

## Log

- 2026-11-15T22:33:55Z [li] created (todo)
- 2026-11-16T04:43:50Z [li] From task 8: FeedItem (cache store) is one row per link with category copied at fetch time; FeedStore.item(link:) finds an item again. Removing a site deletes its cached FeedItems, so History loses them; SavedItem must therefore copy everything it needs (link, title, source, published, dateSource, excerpt, category, notes, savedAt) into the USER store and never depend on FeedItem. The reading view draws a dimmed, inert save mark for this task to make work. Site text is untrusted: clean with the existing FeedRules helpers and show with Text(verbatim:).
- 2026-11-16T04:43:50Z [implementer-2] status: todo → in-progress — claimed by implementer-2
- 2026-11-16T04:58:30Z [implementer-2] Built (commits 821a2d0, d437a1e): SavedItem (user store, full copy at save time, one row per link enforced by lookup, not @Attribute(.unique) which would replace the row and its notes); ReadingItem value type that FeedEntry and SavedItem both produce, so ReadingView opens a saved article whose FeedItem is gone; SavedModel (save/unsave/remove, notes drafts held in the model, debounced 0.8s, flushed on focus loss, Saved appear/disappear/Close, and scene leaving active in both Saved and TodayView; a failed write keeps the draft, shows notesNotSaved with Try again, Close asks first); ArticleQuery/HistoryList pure search and filter (title+source, case/diacritic/width-insensitive, curly quotes folded, plain in-memory matching; History also drops >7 days at query time); HistoryView (>>), SavedView (asterisk), working save mark in ReadingView (confirm when un-saving with notes); REMOVE confirms only when notes exist (drafts count). PlaceholderScreen.swift deleted; SheetScaffold/statusBarCover moved to Design/SheetScaffold.swift. -debugFeed now adds 3 older items for History; new -debugSaved YES; both samples share one in-memory store so saving a sample never touches the user store.
- 2026-11-16T04:58:30Z [implementer-2] Verified: xcodebuild test on iPhone 17 (iOS 27.2) and iPhone 16 (iOS 18.3.1), built separately, 242 tests in 38 suites passed on each; no warnings from our sources. New tests: SavedModelTests (copy on save, save twice keeps notes/savedAt, unsafe links refused, failed save/remove/notes write, notes kept as typed and capped at 2000, debounce, draft counts as notes, remove drops draft, toggle + confirmation, saved survives FeedModel.remove(site) and an 8-day prune and still yields the same ReadingItem), HistoryTests (search folding, plain-text matching, category, 7-day cut at query time, date line, labels), LocalStoreTests (store written with the pre-SavedItem schema opens with nothing lost and SavedItem lands in the user file; saved items survive a junk cache). In the Simulator (iPhone 17, -debugFeed YES -debugSaved YES): saving from History flips to SAVED, REMOVE on an item with notes shows the confirmation and removes after it, a saved article with no cached feed item opens in the reading view with the saved mark. Screenshots: /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task9/history.png and /private/tmp/claude-501/-Users-li-seasign-seasign-apple/6424297e-83a5-4014-a30d-15ca947f3cb0/scratchpad/task9/saved.png
- 2026-11-16T04:58:31Z [implementer-2] tried: Typing into the History search field with XcodeBuildMCP type_text did not reach the field (screen unchanged; likely the hardware-keyboard quirk in architecture.md). Search is covered by unit tests instead.
- 2026-11-16T04:58:31Z [implementer-2] Open: the UI snapshot shows one unlabeled button next to the CATEGORY menu (it stays after hiding the chevron, so it is probably the system Menu's own element); worth a VoiceOver check. DoGetView builds accessibility labels from interpolated literals ("Mark \(item.title) done"), which become LocalizedStringKeys; user-typed text, not site text, but worth aligning.
- 2026-11-16T04:58:31Z [implementer-2] status: in-progress → review
- 2026-11-16T05:03:54Z [implementer-2] Correction to the earlier 'tried' entry: the cause was the automation, not the app. type_text does not focus a field; after a touch on the field it types normally. Checked in the Simulator (iPhone 17, -debugFeed YES -debugSaved YES): typed a note, tapped Close, reopened Saved and the note was there; search 'quantum' narrowed Saved to one row and Clear search restored all; the CATEGORY menu lists All/Physics/Sci and picking Physics filtered to that item. Release build (iPhone 17) succeeded with no warnings from our code. Tests rerun at HEAD (after d437a1e): 242/242 on iPhone 17 (iOS 27.2) and 242/242 on iPhone 16 (iOS 18.3.1).
- 2026-11-16T05:05:28Z [implementer-2] criterion 1 met: History lists items from the last 7 days and nothing older; search and category filter work
- 2026-11-16T05:05:28Z [implementer-2] criterion 2 met: Saving from History or the reading view adds the item to Saved; notes persist; Remove deletes it
- 2026-11-16T05:05:28Z [implementer-2] criterion 3 met: Simulator screenshots of History and Saved recorded in the task log; Saved resembles ref-img/00-save-list.png
- 2026-11-16T05:05:28Z [implementer-2] criterion 4 met: Tests pass on both simulators
- 2026-11-16T05:05:28Z [implementer-2] review (lead): ran the suite on iPhone 16 (iOS 18.3.1) and iPhone 17 (iOS 27.2) at d437a1e: 242 tests passed on each. Viewed saved.png: search field, category menu, caps titles, source and date with REMOVE, notes lines, close to ref-img/00-save-list.png. Light visual review at the user's request. Saved items live in the user store and are covered by savedSurvivesSiteRemovalAndPruning and two LocalStore tests.
- 2026-11-16T05:05:28Z [implementer-2] status: review → done
