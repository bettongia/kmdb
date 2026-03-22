# Product Guidelines: kmdb

## Prose Style
- **Clarity and Precision**: All documentation and API comments should be clear, concise, and technically accurate.
- **Tone**: Maintain a professional and helpful tone. Avoid unnecessary jargon.
- **Consistency**: Use consistent terminology throughout the codebase and documentation.

## Branding
- **Name**: Always use `kmdb` in lowercase unless it starts a sentence.
- **Identity**: Emphasize performance, reliability, and pure Dart implementation.

## UX Principles
- **API First**: The primary user interface is the API. It should be intuitive, discoverable, and consistent.
- **Error Handling**: Provide meaningful error messages and handle edge cases gracefully.
- **Zero-Config**: Aim for a "batteries-included" experience where the database works out-of-the-box with sensible defaults.

## Code and Architecture Guidelines
- **Pure Dart**: Avoid third-party dependencies unless absolutely necessary.
- **Cross-Platform**: Ensure all code is compatible with mobile, desktop, and web.
- **Extreme Testing**: Maintain near-100% test coverage for all core database operations.
- **Corruption Resilience**: Include specific tests to ensure the system handles and recovers from database corruption gracefully.
- **ACID Adherence**: Prioritize data integrity and reliability in all architectural decisions.
