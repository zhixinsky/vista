# iOS 17/18 integration status

Branch: `codex/ios17-backend`. Experimental, incomplete, not device validated.

## Verified source evidence

The supplied CarPlayMaker 5.2.7 (19) IPA attributes KernelDirect to Drift and 3106. MinimumOSVersion 17.0 and embedded backend symbols do not independently prove working wallpaper writes.

Drift's pinned premise explicitly states that its kernel route needs no pairing, tunnel or App Group:
https://github.com/soci-art/Drift/blob/60cae0235b88c835976207eeaffdae9e7f578f5b/Drift/Core/KernelDirectPremise.swift

The stated version bands are 17.0–17.7.x and 18.0–18.7.1. The pinned premise accepts iPhone11,x–iPhone17,x and excludes iPads. Eligibility is not a device success guarantee.

All 18 imported KernelDirect files were checked against Git blob hashes at commit `60cae0235b88c835976207eeaffdae9e7f578f5b`; all matched. Source and license files were preserved.

## Current integration gaps

- Swift candidate selection and the native session gate now both cover 17.0–17.7.x and 18.0–18.7.1. Runtime success is unverified.
- With an established session, CCEngine now lists native application-container children and validates UUID and bundle identity. The legacy backend retains WQFiles inode enumeration. Native listing failure is not silently treated as successful discovery.
- Maintenance accepts an established session or the legacy App Group prerequisite. It never initializes a kernel session. Successful explicit self-check schedules maintenance and clears its throttle; maintenance is deferred while self-check is active.
- The self-check assumes 12 editable wallpaper files. This assumption needs device evidence for each supported system generation.
- Session readiness does not establish access to the actual CarPlay cache or successful wallpaper replacement.
- The imported low-level sources contain arm64 assembly; simulator compilation cannot be assumed to work.

## Validation status

`git diff --check` passed. Swift/Xcode tools are absent from the current Windows environment; compilation and XCTest were not run. PyYAML is absent; project YAML was inspected but not parser-validated. No IPA was built and no device test was performed.

A prior combined backend modification and validation command was rejected with `blocked by policy`; no detailed reason was returned. This report does not treat that rejection as proof that all unrelated edits are prohibited.

Before release, require a physical-device build and evidence for cold self-check without App Group, correct CarPlay container identity, cache discovery, backup, one replacement with readback, restore, and actual display after CarPlay refresh. Do not label the current branch as completed iOS 17/18 support.

## Latest file-only changes

Updated CCKernelSession.m, CCEngine.m and Workshop.swift using direct file reads/writes. No shell, Git, compiler, simulator or device process was started. The kernel primitive sources were not modified. Native directory listing, version gate parity, method declarations and maintenance call order were reviewed statically; this is not a compiler or runtime test.
