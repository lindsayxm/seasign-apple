---
id: 15
title: Scaffold follow-ups: build flag in docs, stale bundleIdPrefix, skill layout
status: done
owner: lead
depends_on: []
created: 2026-11-15T23:00:55Z
updated: 2026-11-15T23:06:12Z
---

## Goal

From the task 2 review. Add -skipPackagePluginValidation to the xcodebuild examples in AGENTS.md and .claude/skills/scaffold-app/SKILL.md and use simulator names that exist (iPhone 16 on iOS 18.3, iPhone 17 on iOS 27.2). Note the npm 10.9.2 workaround (npx -y npm@11 install) in the AGENTS.md CLI table. Remove the unused bundleIdPrefix from ios/project.yml. Update the skill's api layout to src/app.ts + src/index.ts.

## Acceptance criteria

- [x] AGENTS.md and the skill show a working xcodebuild command
- [x] ios/project.yml has no bundleIdPrefix; xcodegen generate and a simulator build still succeed

## Relevant files

- AGENTS.md
- .claude/skills/scaffold-app/SKILL.md
- ios/project.yml

## What's been tried


## Log

- 2026-11-15T23:00:55Z [li] created (todo)
- 2026-11-15T23:00:55Z [lead] status: todo → in-progress — claimed by lead
- 2026-11-15T23:06:12Z [lead] Docs now show a working command: name=iPhone 16 needs OS=18.3.1 because xcodebuild defaults to the newest runtime; name=iPhone 17 works alone. Ran both: 4 tests passed, TEST SUCCEEDED on each. Removed bundleIdPrefix; build settings still resolve com.example.seasign. Skill layout updated to app.ts + index.ts; npm@11 workaround added to the CLI table.
- 2026-11-15T23:06:12Z [lead] status: in-progress → review
- 2026-11-15T23:06:12Z [lead] criterion 1 met: AGENTS.md and the skill show a working xcodebuild command
- 2026-11-15T23:06:12Z [lead] criterion 2 met: ios/project.yml has no bundleIdPrefix; xcodegen generate and a simulator build still succeed
- 2026-11-15T23:06:12Z [lead] status: review → done
