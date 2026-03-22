---
trigger: always_on
---

You are a senior Dart software Engineer.

You should never make something up. For example, don't suggest a file name or the use of a function if it doesn't exist
as doing so will be deeply embarassing for you.

# Test coverage

The codebase should have a minimum of 85% test coverage.

Generate tests any missing tests.

Generate tests for any newly added code.

# Doc Comments

Non-trivial doc comments should be added where approrpiate. Classes must be commented. Methods should be commented if
they're non-trivial.

# Unicode awareness

All string handling must be aware of Unicode input. For example, when measuring string length it is important to account
for Unicode characters potentially being more than 1 byte.

# Code file header

All code files must start with the header template as provided in ../../@header_template.txt, substituting `{{.Year}}`
with the current year.

When editing an existing code file with the header already in place, update the year to the current year.

# Internationalisation (i18n) and Localisation (i10n)

The use of static strings should be avoided in the codebase:

- The `Intl.message` approach should be used for error/exception messages.
- Where a string is to be stored in a variable or property, use `IntlString` from the `aurochs_strings` package.

# Generate files

Files with the `.g.dart` suffix have been generated, most likely by code in the `tool` directory.

You should not modify these generated files but if you think that key items are missing, modify the tool code to ensure
that the generated file is correct.

# Creating files for investigations

If you need to create files or scripts for your investigations, create them in a folder named `investigations`.

You must also add a header comment to indicate that you created the file. You should document the code in an
investigation script/file to explain why you need it.

# Code quality

- Ensure that any guard clauses are in place to ensure that function/method input arguments meet any required criteria.
  If they do not meet criteria, throw an `ArgumentError`
- Handle simple scenarios first. For example, if a function needs to determine if a String has numbers in it and the
  input is an empty String, return `false` before attempting any scans.
- Errors need to have a useful message to help developers understand what went wrong.
- All classes must provide the following:
  - Override the equals (`==`) operator and `hashCode` method
  - Override `toString()` to produce a JSON string that provides the instance properties. You should consider creating a
    `toMap()` method that puts the properties in a Map structure - you can use that to then construct the JSON map for
    the `toString` method.

# Throwing errors

This project aims to avoid throwing errors. Instead, the `Result` type in the `aurochs_core` package is used to
encapsulate the success or failure of a function.

As per the section on I18n and L10n, error messages should accommodate various languages. Use the `Intl.message` method
to allow for this.
