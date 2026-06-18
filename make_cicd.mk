
# A basic pipeline check that relies only on Dart
cicd_build: prepare format_check analyze license_check test_dart
.PHONY: cicd
