# Review — Known False Positives

This file records empirically refuted code-review claims that reviewers must not repeat.

This registry is append-only: add entries, but do not rewrite or remove earlier refutations. Each entry must record
the refuted CLAIM, why it is WRONG, and the DISPROVING COMMAND plus observed output. Use real commands only; never
fake command output.

## PEP 758 parenthesis-free multi-exception handlers

- **Refuted claim (false):** A reviewer claimed `except A, B` / `except ValueError, TypeError:` is a Python 2-only
  form, a SyntaxError, or cannot run on modern Python.
- **Why it is wrong:** PEP 758, accepted for Python 3.14, makes `except` and `except*` accept a parenthesis-free tuple
  of exception types. In Python 3.14+, `except ValueError, TypeError:` is valid modern syntax and is not the Python 2
  `except E, name:` capture form. This false CRITICAL fired 3 times in a real adopting project.
- **Disproving command and observed output:**

  ```sh
  python3 -c "import ast; ast.parse('try:\n    pass\nexcept ValueError, TypeError:\n    pass')"
  ```

  On Python 3.14+, the command exits with status 0 and no output. On Python versions earlier than 3.14 it raises
  `SyntaxError`, which is the version boundary: reviewers must execute on the reviewed HEAD's interpreter instead of
  assuming the syntax is invalid.
