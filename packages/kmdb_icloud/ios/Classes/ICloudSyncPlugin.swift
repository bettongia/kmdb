// Copyright 2026 The Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import CloudKit
import Flutter

// ── Plugin entry point ─────────────────────────────────────────────────────

/// Flutter plugin that bridges the Dart `ICloudSyncChannel` interface to the
/// native CloudKit framework.
///
/// Registered automatically by Flutter's plugin system. Callers do not
/// interact with this class directly — they use the Dart
/// `PlatformICloudSyncChannel` which sends method-channel calls here.
///
/// ## Channel methods
///
/// | Method           | Args                                                | Returns     |
/// | ---------------- | --------------------------------------------------- | ----------- |
/// | `initialize`     | `containerIdentifier: String, syncRoot: String`     | `void`      |
/// | `list`           | `remoteDir: String`, `extension?: String`           | `[String]`  |
/// | `download`       | `remotePath: String`                                | `Data?`     |
/// | `upload`         | `remotePath: String`, `bytes: Data`                 | `void`      |
/// | `delete`         | `remotePath: String`                                | `void`      |
/// | `compareAndSwap` | `remotePath: String`, `bytes: Data`, `ifMatchEtag?: String` | `Bool` |
/// | `getEtag`        | `remotePath: String`                                | `String?`   |
public class KmdbIcloudPlugin: NSObject, FlutterPlugin {
    // ── Plugin registration ───────────────────────────────────────────────

    public static func register(with registrar: FlutterPluginRegistrar) {
#if os(macOS)
        let channel = FlutterMethodChannel(
            name: "kmdb_icloud/sync",
            binaryMessenger: registrar.messenger
        )
#else
        let channel = FlutterMethodChannel(
            name: "kmdb_icloud/sync",
            binaryMessenger: registrar.messenger()
        )
#endif
        let instance = KmdbIcloudPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    // ── State ─────────────────────────────────────────────────────────────

    /// The CloudKit container, populated by the `initialize` call.
    private var container: CKContainer?

    /// The CloudKit private database, populated by the `initialize` call.
    private var database: CKDatabase?

    /// The active zone ID for this sync root, populated lazily by
    /// `ensureZoneExists`.
    ///
    /// One adapter instance always operates against a single zone
    /// (`kmdb-<syncRoot>`), so this is a single value rather than a
    /// name-keyed cache.
    private var zoneID: CKRecordZone.ID?

    /// The zone name derived from `syncRoot`, populated by `initialize`.
    private var zoneName: String?

    // ── Method dispatch ────────────────────────────────────────────────────

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {
        case "initialize":
            handleInitialize(args: args, result: result)
        case "list":
            handleList(args: args, result: result)
        case "download":
            handleDownload(args: args, result: result)
        case "upload":
            handleUpload(args: args, result: result)
        case "delete":
            handleDelete(args: args, result: result)
        case "compareAndSwap":
            handleCompareAndSwap(args: args, result: result)
        case "getEtag":
            handleGetEtag(args: args, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // ── initialize ────────────────────────────────────────────────────────

    /// Initialises the CloudKit container, private database, and zone name.
    ///
    /// Must be called before any other method. Idempotent: calling it again
    /// with the same arguments resets state (to support reconfiguration in
    /// tests). The custom zone is created lazily on the first write operation.
    private func handleInitialize(args: [String: Any], result: @escaping FlutterResult) {
        guard let identifier = args["containerIdentifier"] as? String else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "initialize: containerIdentifier is required",
                details: nil
            ))
            return
        }
        guard let syncRoot = args["syncRoot"] as? String else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "initialize: syncRoot is required",
                details: nil
            ))
            return
        }
        container = CKContainer(identifier: identifier)
        database = container?.privateCloudDatabase
        // Derive the CloudKit zone name from the syncRoot.
        zoneName = "kmdb-\(syncRoot)"
        // Reset the cached zone ID so a new zone is looked up / created.
        zoneID = nil
        result(nil)
    }

    // ── list ──────────────────────────────────────────────────────────────

    /// Lists records whose `path` field begins with `remoteDir + "/"`.
    ///
    /// Returns bare filenames (the `remoteDir/` prefix is stripped).
    /// Optionally filters to filenames ending with [extension].
    ///
    /// Note (N-2): the `path` field must be declared queryable (indexed) in the
    /// CloudKit Dashboard for `BEGINSWITH` predicates to work in production.
    private func handleList(args: [String: Any], result: @escaping FlutterResult) {
        guard let db = database else {
            result(FlutterError(code: "NOT_INITIALIZED", message: "Call initialize first", details: nil))
            return
        }
        guard let remoteDir = args["remoteDir"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "list: remoteDir is required", details: nil))
            return
        }
        let ext = args["extension"] as? String

        // Ensure the zone exists before querying; if it doesn't, no records
        // can exist yet so we return an empty list.
        ensureZoneExists(db: db) { resolvedZoneID, zoneError in
            guard let resolvedZoneID = resolvedZoneID else {
                if let error = zoneError {
                    result(self.mapError(error))
                } else {
                    result([String]())
                }
                return
            }

            let prefix = remoteDir + "/"
            // N-2: BEGINSWITH on 'path' requires the field to be declared
            // queryable in the CloudKit Dashboard schema configuration.
            let predicate = NSPredicate(format: "path BEGINSWITH %@", prefix)
            let query = CKQuery(recordType: "KMDBSyncFile", predicate: predicate)
            let operation = CKQueryOperation(query: query)
            operation.zoneID = resolvedZoneID

            var filenames: [String] = []

            // recordMatchedBlock is called once per matching record.
            operation.recordMatchedBlock = { _, recordResult in
                switch recordResult {
                case .success(let record):
                    if let path = record["path"] as? String {
                        let filename = String(path.dropFirst(prefix.count))
                        // Skip paths with "/" — they are nested records, not
                        // direct children of remoteDir.
                        guard !filename.contains("/") else { return }
                        if let ext = ext {
                            if filename.hasSuffix(ext) { filenames.append(filename) }
                        } else {
                            filenames.append(filename)
                        }
                    }
                case .failure:
                    break // Non-fatal for individual records in a list.
                }
            }

            operation.queryResultBlock = { queryResult in
                switch queryResult {
                case .success:
                    result(filenames)
                case .failure(let error):
                    result(self.mapError(error))
                }
            }
            db.add(operation)
        }
    }

    // ── download ──────────────────────────────────────────────────────────

    /// Downloads the CKAsset bytes for the record at [remotePath].
    ///
    /// Returns `nil` (Flutter `null`) when `CKError.unknownItem`.
    private func handleDownload(args: [String: Any], result: @escaping FlutterResult) {
        guard let db = database else {
            result(FlutterError(code: "NOT_INITIALIZED", message: "Call initialize first", details: nil))
            return
        }
        guard let remotePath = args["remotePath"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "download: remotePath is required", details: nil))
            return
        }

        ensureZoneExists(db: db) { resolvedZoneID, zoneError in
            guard let resolvedZoneID = resolvedZoneID else {
                // Zone doesn't exist yet → file cannot exist.
                result(nil)
                return
            }

            let recordID = CKRecord.ID(recordName: remotePath, zoneID: resolvedZoneID)
            db.fetch(withRecordID: recordID) { record, error in
                if let ckError = error as? CKError {
                    if ckError.code == .unknownItem { result(nil); return }
                    result(self.mapError(ckError))
                    return
                }
                if let error = error {
                    result(FlutterError(code: "CLOUDKIT_ERROR", message: error.localizedDescription, details: nil))
                    return
                }
                guard let record = record,
                      let asset = record["content"] as? CKAsset,
                      let fileURL = asset.fileURL else {
                    result(nil)
                    return
                }
                do {
                    let data = try Data(contentsOf: fileURL)
                    result(FlutterStandardTypedData(bytes: data))
                } catch {
                    result(FlutterError(code: "READ_ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    // ── upload ────────────────────────────────────────────────────────────

    /// Uploads [bytes] as the `content` CKAsset on the record at [remotePath].
    ///
    /// Uses `savePolicy: .changedKeys` — creates if the record is new, updates
    /// if it already exists. This avoids a separate existence check
    /// (N-1 reconciliation: single savePolicy approach).
    private func handleUpload(args: [String: Any], result: @escaping FlutterResult) {
        guard let db = database else {
            result(FlutterError(code: "NOT_INITIALIZED", message: "Call initialize first", details: nil))
            return
        }
        guard let remotePath = args["remotePath"] as? String,
              let bytesData = args["bytes"] as? FlutterStandardTypedData else {
            result(FlutterError(code: "INVALID_ARGS", message: "upload: remotePath and bytes are required", details: nil))
            return
        }

        ensureZoneExists(db: db) { resolvedZoneID, zoneError in
            if let error = zoneError {
                result(self.mapError(error))
                return
            }
            guard let resolvedZoneID = resolvedZoneID else {
                result(FlutterError(code: "ZONE_ERROR", message: "Failed to create zone", details: nil))
                return
            }

            let recordID = CKRecord.ID(recordName: remotePath, zoneID: resolvedZoneID)
            let record = CKRecord(recordType: "KMDBSyncFile", recordID: recordID)
            record["path"] = remotePath as CKRecordValue

            // Write bytes to a temporary file so CKAsset can reference it.
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            do {
                try bytesData.data.write(to: tempURL)
            } catch {
                result(FlutterError(code: "WRITE_ERROR", message: error.localizedDescription, details: nil))
                return
            }
            record["content"] = CKAsset(fileURL: tempURL)

            // savePolicy: .changedKeys — creates a new record when none
            // exists, updates changed fields on an existing record.
            let op = CKModifyRecordsOperation(
                recordsToSave: [record], recordIDsToDelete: nil
            )
            op.savePolicy = .changedKeys

            op.modifyRecordsResultBlock = { opResult in
                try? FileManager.default.removeItem(at: tempURL)
                switch opResult {
                case .success: result(nil)
                case .failure(let error): result(self.mapError(error))
                }
            }
            db.add(op)
        }
    }

    // ── delete ────────────────────────────────────────────────────────────

    /// Deletes the record at [remotePath]. No-op if not found.
    private func handleDelete(args: [String: Any], result: @escaping FlutterResult) {
        guard let db = database else {
            result(FlutterError(code: "NOT_INITIALIZED", message: "Call initialize first", details: nil))
            return
        }
        guard let remotePath = args["remotePath"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "delete: remotePath is required", details: nil))
            return
        }

        // If the zone hasn't been created yet there are no records to delete.
        guard let resolvedZoneID = zoneID else {
            result(nil)
            return
        }

        let recordID = CKRecord.ID(recordName: remotePath, zoneID: resolvedZoneID)
        let op = CKModifyRecordsOperation(
            recordsToSave: nil, recordIDsToDelete: [recordID]
        )

        op.modifyRecordsResultBlock = { opResult in
            switch opResult {
            case .success:
                result(nil)
            case .failure(let error):
                if let ckError = error as? CKError, ckError.code == .unknownItem {
                    result(nil) // Idempotent — not found is not an error.
                    return
                }
                result(self.mapError(error))
            }
        }
        db.add(op)
    }

    // ── compareAndSwap ─────────────────────────────────────────────────────

    /// Conditionally writes [bytes] to [remotePath].
    ///
    /// Returns `true` on success, `false` on CAS failure.
    private func handleCompareAndSwap(args: [String: Any], result: @escaping FlutterResult) {
        guard let db = database else {
            result(FlutterError(code: "NOT_INITIALIZED", message: "Call initialize first", details: nil))
            return
        }
        guard let remotePath = args["remotePath"] as? String,
              let bytesData = args["bytes"] as? FlutterStandardTypedData else {
            result(FlutterError(code: "INVALID_ARGS", message: "compareAndSwap: remotePath and bytes are required", details: nil))
            return
        }
        let ifMatchEtag = args["ifMatchEtag"] as? String

        ensureZoneExists(db: db) { resolvedZoneID, zoneError in
            if let error = zoneError {
                result(self.mapError(error))
                return
            }
            guard let resolvedZoneID = resolvedZoneID else {
                result(FlutterError(code: "ZONE_ERROR", message: "Failed to create zone", details: nil))
                return
            }

            // Write bytes to a temporary file for the CKAsset.
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            do {
                try bytesData.data.write(to: tempURL)
            } catch {
                result(FlutterError(code: "WRITE_ERROR", message: error.localizedDescription, details: nil))
                return
            }

            if let etag = ifMatchEtag {
                // Update-if-match: fetch the current server record so we have
                // its recordChangeTag, verify it matches, then resave with
                // .ifServerRecordUnchanged for atomicity.
                self.casUpdate(
                    db: db,
                    remotePath: remotePath,
                    zoneID: resolvedZoneID,
                    expectedEtag: etag,
                    bytesData: bytesData.data,
                    tempURL: tempURL,
                    result: result
                )
            } else {
                // Create-if-absent: savePolicy .allKeys on a local record with
                // no recordChangeTag.  CloudKit returns .serverRecordChanged if
                // a record with that ID already exists — at most one winner per
                // zone (pending Phase 4a empirical verification).
                let recordID = CKRecord.ID(recordName: remotePath, zoneID: resolvedZoneID)
                let record = CKRecord(recordType: "KMDBSyncFile", recordID: recordID)
                record["path"] = remotePath as CKRecordValue
                record["content"] = CKAsset(fileURL: tempURL)

                let op = CKModifyRecordsOperation(
                    recordsToSave: [record], recordIDsToDelete: nil
                )
                op.savePolicy = .allKeys

                op.modifyRecordsResultBlock = { opResult in
                    try? FileManager.default.removeItem(at: tempURL)
                    switch opResult {
                    case .success:
                        result(true)
                    case .failure(let error):
                        if let ckError = error as? CKError,
                           ckError.code == .serverRecordChanged {
                            result(false) // Record already exists — CAS failed.
                            return
                        }
                        result(self.mapError(error))
                    }
                }
                db.add(op)
            }
        }
    }

    /// Two-step conditional update for the update-if-match CAS path.
    ///
    /// CloudKit's conditional update requires the full server `CKRecord`
    /// (with its `recordChangeTag`) for `savePolicy: .ifServerRecordUnchanged`
    /// to enforce the precondition.  We therefore:
    ///
    /// 1. Fetch the current server record.
    /// 2. Verify its `recordChangeTag` equals `expectedEtag`.
    /// 3. Resave the record with the new content under `.ifServerRecordUnchanged`.
    ///
    /// Step 3 is atomic from CloudKit's perspective: if another writer has
    /// changed the record between steps 1 and 3, CloudKit returns
    /// `.serverRecordChanged` and we return `false`.
    private func casUpdate(
        db: CKDatabase,
        remotePath: String,
        zoneID: CKRecordZone.ID,
        expectedEtag: String,
        bytesData: Data,
        tempURL: URL,
        result: @escaping FlutterResult
    ) {
        let recordID = CKRecord.ID(recordName: remotePath, zoneID: zoneID)

        // Step 1: fetch the current server record.
        db.fetch(withRecordID: recordID) { serverRecord, fetchError in
            if let ckError = fetchError as? CKError {
                try? FileManager.default.removeItem(at: tempURL)
                if ckError.code == .unknownItem {
                    result(false) // Record not found — update-if-match fails.
                    return
                }
                result(self.mapError(ckError))
                return
            }
            if let error = fetchError {
                try? FileManager.default.removeItem(at: tempURL)
                result(FlutterError(code: "CLOUDKIT_ERROR", message: error.localizedDescription, details: nil))
                return
            }
            guard let serverRecord = serverRecord else {
                try? FileManager.default.removeItem(at: tempURL)
                result(false)
                return
            }

            // Step 2: verify ETag matches.
            let serverEtag = serverRecord.recordChangeTag ?? ""
            guard serverEtag == expectedEtag else {
                try? FileManager.default.removeItem(at: tempURL)
                result(false) // ETag mismatch — another writer changed the record.
                return
            }

            // Step 3: update the server record and save atomically.
            serverRecord["path"] = remotePath as CKRecordValue
            serverRecord["content"] = CKAsset(fileURL: tempURL)

            let op = CKModifyRecordsOperation(
                recordsToSave: [serverRecord], recordIDsToDelete: nil
            )
            op.savePolicy = .ifServerRecordUnchanged

            op.modifyRecordsResultBlock = { opResult in
                try? FileManager.default.removeItem(at: tempURL)
                switch opResult {
                case .success:
                    result(true)
                case .failure(let error):
                    if let ckError = error as? CKError,
                       ckError.code == .serverRecordChanged {
                        result(false) // Another writer won between fetch and save.
                        return
                    }
                    result(self.mapError(error))
                }
            }
            db.add(op)
        }
    }

    // ── getEtag ───────────────────────────────────────────────────────────

    /// Returns the `recordChangeTag` for [remotePath], or `nil` if not found.
    ///
    /// Passes `desiredKeys: []` to avoid downloading the CKAsset content —
    /// only record metadata (including `recordChangeTag`) is fetched.
    private func handleGetEtag(args: [String: Any], result: @escaping FlutterResult) {
        guard let db = database else {
            result(FlutterError(code: "NOT_INITIALIZED", message: "Call initialize first", details: nil))
            return
        }
        guard let remotePath = args["remotePath"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "getEtag: remotePath is required", details: nil))
            return
        }

        // If the zone hasn't been created yet no record can exist.
        guard let resolvedZoneID = zoneID else {
            result(nil)
            return
        }

        let recordID = CKRecord.ID(recordName: remotePath, zoneID: resolvedZoneID)

        // desiredKeys: [] requests metadata-only (recordChangeTag is in the
        // system metadata, not a user field), avoiding an asset download.
        let op = CKFetchRecordsOperation(recordIDs: [recordID])
        op.desiredKeys = []

        op.perRecordResultBlock = { _, recordResult in
            switch recordResult {
            case .success(let record):
                result(record.recordChangeTag)
            case .failure(let error):
                if let ckError = error as? CKError, ckError.code == .unknownItem {
                    result(nil)
                    return
                }
                result(self.mapError(error))
            }
        }
        db.add(op)
    }

    // ── Zone management ────────────────────────────────────────────────────

    /// Ensures the CloudKit custom zone `"kmdb-<syncRoot>"` exists.
    ///
    /// If the zone is already cached in [zoneID], calls [completion]
    /// immediately. Otherwise creates the zone and caches its ID.
    ///
    /// Calls [completion] with `(zoneID, nil)` on success, or
    /// `(nil, error)` on failure.
    private func ensureZoneExists(
        db: CKDatabase,
        completion: @escaping (CKRecordZone.ID?, Error?) -> Void
    ) {
        // Return the cached zone ID if available.
        if let existing = zoneID {
            completion(existing, nil)
            return
        }

        guard let name = zoneName else {
            completion(nil, nil) // Not initialised yet — caller handles nil.
            return
        }

        let zone = CKRecordZone(zoneName: name)
        let op = CKModifyRecordZonesOperation(
            recordZonesToSave: [zone], recordZoneIDsToDelete: nil
        )

        op.modifyRecordZonesResultBlock = { opResult in
            switch opResult {
            case .success:
                self.zoneID = zone.zoneID
                completion(zone.zoneID, nil)
            case .failure(let error):
                completion(nil, error)
            }
        }
        db.add(op)
    }

    // ── Error mapping ──────────────────────────────────────────────────────

    /// Maps a CloudKit or system error to a [FlutterError].
    ///
    /// - `CKError.requestRateLimited` → code `"RATE_LIMITED"` with
    ///   `retryAfterMs` in the details dict (from `CKErrorRetryAfterKey`).
    /// - `CKError.quotaExceeded` → code `"QUOTA_EXCEEDED"`.
    /// - Other CKErrors → code `"CLOUDKIT_ERROR"` with `ckErrorCode` in
    ///   the details dict for diagnostic purposes.
    /// - Non-CKErrors → code `"CLOUDKIT_ERROR"`.
    private func mapError(_ error: Error) -> FlutterError {
        if let ckError = error as? CKError {
            switch ckError.code {
            case .requestRateLimited:
                var details: [String: Any] = ["ckErrorCode": ckError.code.rawValue]
                if let retryAfter = ckError.userInfo[CKErrorRetryAfterKey] as? Double {
                    details["retryAfterMs"] = Int(retryAfter * 1000)
                }
                return FlutterError(
                    code: "RATE_LIMITED",
                    message: ckError.localizedDescription,
                    details: details
                )
            case .quotaExceeded:
                return FlutterError(
                    code: "QUOTA_EXCEEDED",
                    message: ckError.localizedDescription,
                    details: ["ckErrorCode": ckError.code.rawValue]
                )
            default:
                return FlutterError(
                    code: "CLOUDKIT_ERROR",
                    message: ckError.localizedDescription,
                    details: ["ckErrorCode": ckError.code.rawValue]
                )
            }
        }
        return FlutterError(
            code: "CLOUDKIT_ERROR",
            message: error.localizedDescription,
            details: nil
        )
    }
}
