
# A basic pipeline check that relies only on Dart
cicd_build: prepare format_check analyze license_check tests_dart
.PHONY: cicd
