# Used as an included makefile for packages that need to generate translations.

# These are the files that are used as input to intl_translation:extract_to_arb
MESSAGES_SOURCE_INPUT_FILES?=lib/src/*.dart

ARB_DIR=resources/l10n
ARB_BASE_FILE=$(ARB_DIR)/messages_en.arb
ARB_FILES=$(wildcard $(ARB_DIR)/*.arb)
MESSAGES_GENERATED_DIR=lib/src/generated/l10n

.PHONY: lyrebird generate_from_arb extract_to_arb locale_info

locales: extract_to_arb generate_from_arb

extract_to_arb: $(ARB_BASE_FILE)

generate_from_arb: $(ARB_BASE_FILE) $(MESSAGES_GENERATED_DIR)/messages_all.dart

$(ARB_DIR)/%.arb: $(MESSAGES_SOURCE_INPUT_FILES)
	@mkdir -p $(ARB_DIR)
	dart run intl_translation:extract_to_arb \
				--output-file=$(ARB_BASE_FILE) \
				$(MESSAGES_SOURCE_INPUT_FILES)

$(MESSAGES_GENERATED_DIR)/%.dart: $(ARB_FILES)
	@mkdir -p $(MESSAGES_GENERATED_DIR)
	@rm -f $(MESSAGES_GENERATED_DIR)/*.dart
	dart run intl_translation:generate_from_arb \
		--output-dir $(MESSAGES_GENERATED_DIR) \
		$(MESSAGES_SOURCE_INPUT_FILES) \
		$(ARB_DIR)/*.arb

locale_info:
	@echo ARB_DIR: $(ARB_DIR)
	@echo ARB_BASE_FILE: $(ARB_BASE_FILE)
	@echo MESSAGES_GENERATED_DIR: $(MESSAGES_GENERATED_DIR)
	@echo MESSAGES_SOURCE_INPUT_FILES: $(MESSAGES_SOURCE_INPUT_FILES)

lyrebird:
	dart pub global run lyrebird
