import Foundation

func runAllTests() {
    print("================================================================================")
    print("QuickDictate Standalone Test Runner (49 Automated Logic & Integration Tests)")
    print("Platform: macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("Architecture: \(ProcessInfo.processInfo.activeProcessorCount) cores")
    print("================================================================================")

    let testMethods: [(name: String, block: (QuickDictateTests) throws -> Void)] = [
        ("test01_FirstLaunchDefaultsAndSnippetsInitialization", { try $0.test01_FirstLaunchDefaultsAndSnippetsInitialization() }),
        ("test02_LegacyPlaintextKeyMigrationSuccess", { try $0.test02_LegacyPlaintextKeyMigrationSuccess() }),
        ("test03_FailedKeychainMigrationPreservesLegacyFiles", { try $0.test03_FailedKeychainMigrationPreservesLegacyFiles() }),
        ("test04_MultipleAPIKeysAndProviderSelection", { try $0.test04_MultipleAPIKeysAndProviderSelection() }),
        ("test05_AuthenticationFailureReporting", { try $0.test05_AuthenticationFailureReporting() }),
        ("test06_RateLimitResponseAndBoundedFailover", { try $0.test06_RateLimitResponseAndBoundedFailover() }),
        ("test07_NetworkTimeoutAndRequestCancellation", { try $0.test07_NetworkTimeoutAndRequestCancellation() }),
        ("test08_SuccessfulTranscriptionWithMockedResponse", { try $0.test08_SuccessfulTranscriptionWithMockedResponse() }),
        ("test09_InvalidTranscriptionJSONRejectedWithoutFailoverStorm", { try $0.test09_InvalidTranscriptionJSONRejectedWithoutFailoverStorm() }),
        ("test10_EmptyAndCorruptedAudioValidation", { try $0.test10_EmptyAndCorruptedAudioValidation() }),
        ("test11_RecordingLifecycleStateMachineTransitions", { try $0.test11_RecordingLifecycleStateMachineTransitions() }),
        ("test12_TemporaryFileIsolationAndCleanup", { try $0.test12_TemporaryFileIsolationAndCleanup() }),
        ("test13_CancellationPreventsLateResponsePaste", { try $0.test13_CancellationPreventsLateResponsePaste() }),
        ("test14_StandaloneSnippetReplacement", { try $0.test14_StandaloneSnippetReplacement() }),
        ("test15_InlineSnippetReplacementAndPrecedence", { try $0.test15_InlineSnippetReplacementAndPrecedence() }),
        ("test16_MultilineUnicodeAndRegexEscapedSnippets", { try $0.test16_MultilineUnicodeAndRegexEscapedSnippets() }),
        ("test17_MalformedSnippetJSONPreservedNeverOverwritten", { try $0.test17_MalformedSnippetJSONPreservedNeverOverwritten() }),
        ("test18_ClipboardChangeProtectionAndFocusVerification", { try $0.test18_ClipboardChangeProtectionAndFocusVerification() }),
        ("test19_DisabledMicrophoneAndAccessibilityPermissionsHandledSafelyUnattended", { try $0.test19_DisabledMicrophoneAndAccessibilityPermissionsHandledSafelyUnattended() }),
        ("test20_CleanApplicationTerminationAndModifierChordProtection", { try $0.test20_CleanApplicationTerminationAndModifierChordProtection() }),
        ("test21_SnippetRecoveryAbortsWhenSafetyBackupCopyOrVerificationFails", { try $0.test21_SnippetRecoveryAbortsWhenSafetyBackupCopyOrVerificationFails() }),
        ("test22_SnippetRecoveryWithInvalidBackupFailedWriteAndSuccessfulRestore", { try $0.test22_SnippetRecoveryWithInvalidBackupFailedWriteAndSuccessfulRestore() }),
        ("test23_SynchronousKey1FailoverDoesNotOverwriteKey2ActiveTaskOnCancel", { try $0.test23_SynchronousKey1FailoverDoesNotOverwriteKey2ActiveTaskOnCancel() }),
        ("test24_CancellationDuringRetryBackoffStopsScheduledRetryRequest", { try $0.test24_CancellationDuringRetryBackoffStopsScheduledRetryRequest() }),
        ("test25_MissingExpectedTargetNeverAutoPastes", { try $0.test25_MissingExpectedTargetNeverAutoPastes() }),
        ("test26_DifferentWindowOrFocusedElementInSameAppFallsBackToClipboard", { try $0.test26_DifferentWindowOrFocusedElementInSameAppFallsBackToClipboard() }),
        ("test27_EmptyInitialClipboardDoesNotWipePasteboardOnRestore", { try $0.test27_EmptyInitialClipboardDoesNotWipePasteboardOnRestore() }),
        ("test28_PreviewCallbackFromOlderSessionCannotModifyNewerSessionPreviewState", { try $0.test28_PreviewCallbackFromOlderSessionCannotModifyNewerSessionPreviewState() }),
        ("test29_FreshInstallRequiresOnboardingAndBlocksRecordingUntilReady", { try $0.test29_FreshInstallRequiresOnboardingAndBlocksRecordingUntilReady() }),
        ("test30_OnboardingReadinessAndSetupWizardDetection", { try $0.test30_OnboardingReadinessAndSetupWizardDetection() }),
        ("test31_CustomKeyComboValidationAndFormatting", { try $0.test31_CustomKeyComboValidationAndFormatting() }),
        ("test32_CustomKeyComboPersistenceAndCarbonRegistration", { try $0.test32_CustomKeyComboPersistenceAndCarbonRegistration() }),
        ("test33_SingleApplicationIdentityAndZeroHelperProcesses", { try $0.test33_SingleApplicationIdentityAndZeroHelperProcesses() }),
        ("test34_ActivationPolicyAndLaunchpadReopenHandler", { try $0.test34_ActivationPolicyAndLaunchpadReopenHandler() }),
        ("test35_OnboardingStepPersistenceAndRelaunchRestoration", { try $0.test35_OnboardingStepPersistenceAndRelaunchRestoration() }),
        ("test36_OnboardingWelcomeAndAllStepsTextWrappingProperties", { try $0.test36_OnboardingWelcomeAndAllStepsTextWrappingProperties() }),
        ("test37_OnboardingRestartFromBeginningExplicitReset", { try $0.test37_OnboardingRestartFromBeginningExplicitReset() }),
        ("test38_OnboardingCompletionResetsStepToDefault", { try $0.test38_OnboardingCompletionResetsStepToDefault() }),
        ("test39_APIKeyValidatorGroqValidAndInvalidResponses", { try $0.test39_APIKeyValidatorGroqValidAndInvalidResponses() }),
        ("test40_APIKeyValidatorOpenAIValidAndInvalidResponses", { try $0.test40_APIKeyValidatorOpenAIValidAndInvalidResponses() }),
        ("test41_APIKeyValidatorRateLimitAndServerError", { try $0.test41_APIKeyValidatorRateLimitAndServerError() }),
        ("test42_APIKeyValidatorModelUnavailableAndNetworkTimeout", { try $0.test42_APIKeyValidatorModelUnavailableAndNetworkTimeout() }),
        ("test43_APIKeyValidatorCancellationAndGenerationTracking", { try $0.test43_APIKeyValidatorCancellationAndGenerationTracking() }),
        ("test44_OnboardingAccessibilityStateBlocksAdvancingUntilTrusted", { try $0.test44_OnboardingAccessibilityStateBlocksAdvancingUntilTrusted() }),
        ("test45_OnboardingShortcutSelectionKeepDefaultVsCustom", { try $0.test45_OnboardingShortcutSelectionKeepDefaultVsCustom() }),
        ("test46_SecurityNoAPIKeyLeaksInValidationDiagnostics", { try $0.test46_SecurityNoAPIKeyLeaksInValidationDiagnostics() }),
        ("test47_APIKeyValidatorRejectsDifferentWhisperModel", { try $0.test47_APIKeyValidatorRejectsDifferentWhisperModel() }),
        ("test48_APIKeyValidatorSynchronousCancelCallbackDoesNotDeadlock", { try $0.test48_APIKeyValidatorSynchronousCancelCallbackDoesNotDeadlock() }),
        ("test49_UnverifiableFocusOrNewProcessFallsBackToClipboard", { try $0.test49_UnverifiableFocusOrNewProcessFallsBackToClipboard() }),
    ]

    var passedCount = 0
    var failedCount = 0
    let totalStart = Date()

    for (index, test) in testMethods.enumerated() {
        let testInstance = QuickDictateTests()
        currentTestFailures.removeAll()
        let start = Date()
        var errorThrown: Error? = nil

        do {
            try testInstance.setUpWithError()
            try test.block(testInstance)
            try testInstance.tearDownWithError()
        } catch {
            errorThrown = error
        }

        let duration = Date().timeIntervalSince(start)
        let formattedDuration = String(format: "%.3fs", duration)
        let numStr = String(format: "%02d", index + 1)

        if currentTestFailures.isEmpty && errorThrown == nil {
            passedCount += 1
            print("  [\(numStr)/\(testMethods.count)] PASS: \(test.name) (\(formattedDuration))")
        } else {
            failedCount += 1
            print("  [\(numStr)/\(testMethods.count)] FAIL: \(test.name) (\(formattedDuration))")
            if let err = errorThrown {
                print("         Caught Error: \(err.localizedDescription)")
            }
            for f in currentTestFailures {
                print("         Failure: \(f)")
            }
        }
    }

    let totalDuration = Date().timeIntervalSince(totalStart)
    print("================================================================================")
    print("Test Results Summary:")
    print("  Total Scenarios: \(testMethods.count)")
    print("  Passed:          \(passedCount)")
    print("  Failed:          \(failedCount)")
    print("  Execution Time:  \(String(format: "%.2fs", totalDuration))")
    print("================================================================================")

    if failedCount > 0 {
        exit(1)
    }
}

runAllTests()
