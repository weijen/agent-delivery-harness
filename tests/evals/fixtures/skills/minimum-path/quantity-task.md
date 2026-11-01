---
description: Synthetic small change that still needs a real boundary regression test.
---

Update `validate_quantity(quantity)` in quantity.py to raise ValueError when
an integer quantity exceeds MAX_QUANTITY (100). Exactly 100 must remain valid.
Return allowed input unchanged and leave other behavior unchanged.

Add and execute a regression test covering the new rejection behavior.
No new configuration, dependencies, or other validation rules are requested.
