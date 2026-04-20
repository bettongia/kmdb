## detect_test.dart — one remaining failure

`magic matches test.key: application/vnd.apple.keynote` — magic-only detection
returns `application/zip` instead of `application/vnd.apple.keynote`. Two
options:

1. **Update the test expectation** to `application/zip` for the magic-only case.
   The full match and glob-only cases already return the correct
   `application/vnd.apple.keynote` (the `_merge` logic handles it). The
   magic-only test is asserting behaviour the registry cannot currently deliver.

2. **Improve the Keynote magic pattern** in the source XML / generated data. The
   current pattern looks for `index.apxl` at byte offset 30 inside the ZIP local
   file header, but modern Keynote files store their content under
   `Index/Document.iwa` (same structure used by Pages and Numbers). Adding that
   as an alternative sub-match would let magic alone identify Keynote — but
   Pages and Numbers use the same path, so a more specific marker inside the ZIP
   would be needed (e.g. checking for a Keynote-specific filename further into
   the archive). This is likely not worth the effort for an initial release.

   Related: Pages/Numbers magic patterns are also ambiguous with each other
   (both match `index.xml` or `Index/Document.iwa`), so magic-only cannot
   reliably distinguish them. The glob (file extension) is the reliable signal
   for Apple iWork formats.

## Language files

[ ] Handle the
[PO format](https://www.gnu.org/software/gettext/manual/html_node/PO-Files.html)
for the
[language files](https://gitlab.freedesktop.org/xdg/shared-mime-info/-/tree/master/po) -
this is not critical for the initial release. I'll look to create a new package
named `convert_po`.

## Allow additional and overriden entries

[ ] Allow the user to provide a supplemental registry entries that are additive
or replace entries from the default registry
