# Production target and UI verification

- Mirror Designer (`designer/`) targets **Android only** for production right now.
- Always verify production behavior end to end on **live hardware: the attached Android phone (Pixel 2) and the Developer 1 mirror/display**. Developer 1 is available for verification; use its real connection and confirm the result on the physical display as well as the phone.
- Do not launch, screenshot, or spend verification time on the Linux/PC application as a substitute for Android verification.
- Do not expand a production UI task into desktop-specific changes unless explicitly requested.
- The local simulator, an Android emulator, and phone-only checks are not substitutes for live phone-plus-display verification. Do not use them as final verification unless the user explicitly requests it.
- If either live device or the means to observe its result is unavailable, report the specific blocker; do not silently switch to simulator, emulator, or desktop.

This is an explicit user preference, recorded after correction on 2026-09-27.
