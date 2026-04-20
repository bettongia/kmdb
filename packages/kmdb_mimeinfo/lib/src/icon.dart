// Copyright 2026 The KMDB Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/// Standard FreeDesktop generic icon names.
enum GenericIcon {
  applicationXExecutable('application-x-executable'),
  audioXGeneric('audio-x-generic'),
  emblemSymbolicLink('emblem-symbolic-link'),
  folder('folder'),
  fontXGeneric('font-x-generic'),
  imageXGeneric('image-x-generic'),
  mediaFloppy('media-floppy'),
  mediaOptical('media-optical'),
  packageXGeneric('package-x-generic'),
  textHtml('text-html'),
  textXGeneric('text-x-generic'),
  textXGenericTemplate('text-x-generic-template'),
  textXScript('text-x-script'),
  videoXGeneric('video-x-generic'),
  xOfficeAddressBook('x-office-address-book'),
  xOfficeCalendar('x-office-calendar'),
  xOfficeDocument('x-office-document'),
  xOfficePresentation('x-office-presentation'),
  xOfficeSpreadsheet('x-office-spreadsheet');

  final String value;
  const GenericIcon(this.value);

  static GenericIcon? tryParse(String value) {
    for (var icon in GenericIcon.values) {
      if (icon.value == value) {
        return icon;
      }
    }
    return null;
  }

  @override
  String toString() => value;
}
