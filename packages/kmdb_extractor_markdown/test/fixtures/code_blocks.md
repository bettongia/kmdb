Prose before the fenced code block.

```dart
final consoleOnlyCodeToken = computeSomethingWithFencedCodeTokens();
print(consoleOnlyCodeToken);
```

Prose after the fenced code block, with an inline `codeSpanToken()` kept.

    an indented code block with indentedCodeToken should also be dropped

Prose after the indented code block.
