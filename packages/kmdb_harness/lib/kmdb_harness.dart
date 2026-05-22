// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/// KMDB developer test harness for multi-device sync protocol validation.
///
/// This library provides a deterministic, seeded harness that orchestrates
/// multiple KMDB device instances, drives them with a generated action
/// sequence, captures every write and sync event, and verifies that each
/// device reaches the expected post-sync state.
///
/// ## Quick start
///
/// ```dart
/// import 'package:kmdb/kmdb.dart';
/// import 'package:kmdb_harness/kmdb_harness.dart';
///
/// final manager = TestManager(
///   config: HarnessConfig(
///     syncAdapter: MemorySyncAdapter(),
///     velocityPreset: VelocityPreset.one,
///     duration: Duration(seconds: 5),
///   ),
/// );
/// final report = await manager.run();
/// print('Passed: ${report.passed}');
/// ```
library;

// ── Configuration ─────────────────────────────────────────────────────────────
export 'src/config.dart'
    show DocSizeDistribution, HarnessConfig, KeyPoolRatios, VelocityPreset;

// ── Actions ───────────────────────────────────────────────────────────────────
export 'src/actions.dart' show Action, ActionResult, ActionType;

// ── Actors ────────────────────────────────────────────────────────────────────
export 'src/device.dart' show Device, DeviceState;
export 'src/user_agent.dart' show UserAgent;
export 'src/partitionable_adapter.dart'
    show NetworkPartitionException, PartitionableAdapter;

// ── Reconciliation ────────────────────────────────────────────────────────────
export 'src/reconciliation_agent.dart'
    show ForkEvent, ReconciliationAgent, SyncLogEntry, WriteLogEntry;

// ── Reporting ─────────────────────────────────────────────────────────────────
export 'src/report.dart'
    show
        DeviceVerdict,
        ForkRecord,
        HarnessReport,
        KeyMismatch,
        NoOpCount,
        ReportDiff,
        diffReports;

// ── Orchestration ─────────────────────────────────────────────────────────────
export 'src/test_manager.dart'
    show HarnessConfigException, QuotaAwareAdapter, TestManager;
