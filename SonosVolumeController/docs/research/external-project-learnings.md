# External Project Learnings

## CodexBar
Top learning: Pair every permission request with a short, plain-language explanation of why it is needed and what data it touches.

Suggested application: Expand our Accessibility and network-discovery messaging to explain the exact scope (no audio capture, only hotkey detection and LAN discovery), plus a clear opt-out path.

## sonoscli
Top learning: Keep control flows coordinator-aware so group commands always target the coordinator, even if the user selected a member.

Suggested application: Ensure selection and playback/transport calls resolve to the group coordinator while keeping member-level volume adjustments scoped to members.
