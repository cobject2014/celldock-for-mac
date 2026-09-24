# Backup data inventory

Audit of persistent storage in Sources/CellDock; no live user secrets inspected.

| Owner | Data | Migration |
|---|---|---|
| MessageStore | messages.json, deleted-message-ids.json | Include; missing collection is empty; preserve read/deletion state |
| MessageStore | messages.backup.json | Exclude redundant recovery copy; rebuild from restored messages |
| CallHistoryStore | calls.json | Include historical module attribution and recording IDs |
| CallRecordingStore | recordings.json, Recordings/* | Include unchanged bytes; missing indexed audio is an error |
| AlertSoundService | Sounds/*, per-kind selected sound/name keys | Include locally imported resources (already relative names) |
| Appearance/language | CellDockAppearanceMode.v1, CellDock.AppLanguage.v1 | Include |
| AppState | AutomaticallyAnswerCalls.v1, AutomaticAnswerDelay.v1, AutomaticallyRecordCalls.v1, AutoDeleteReadVerificationMessages.v1 | Include; automation disabled pending target confirmation |
| AppState | HideMenuBarIconWhenDisconnected.v1, ShowsMenuBarNetworkSpeed.v1 | Include |
| PrivacyPresentation | PresentationPrivacyProtectionEnabled.v1, PresentationPrivacyAliasSalt.v1 | Include |
| UI | CommunicationSidebarWidth.v1, NetworkToolsSelectedTab.v1 | Include |
| UpdaterManager | CellDockUpdateChannel | Include app preference, not Sparkle runtime state |
| Recording consent | CallRecordingConsentAcknowledged.v1 | Reconfirm on target |
| SMSForwardingStore | SMSForwardingSettings.v1 | Include original flags; hold until target confirmation |
| SMSForwardingCredentialStore | bark.serverURL, feishu.webhookURL, feishu.secret, dingtalk.accessToken, dingtalk.secret, wecom.webhookURL | Include from exact app.celldock.mac.sms-forwarding service; read errors fail backup |
| SOCKSProxyStore | SOCKSProxyConfigurations.v1 + app.celldock.mac.socks-proxy entries for referenced IDs | Include; disable listeners pending target confirmation |
| VoWiFiUpstreamProxyStore | VoWiFiUpstreamProxies.v1 and referenced app.celldock.mac.vowifi-upstream passwords | Include |
| VoWiFiUpstreamProxyStore | VoWiFiUpstreamRoutes.v1 | Preserve as migration information, require module reassignment |
| CellularNetworkingPreferenceStore | CellularNetworkingModeByModule.v2, CellularNetworkingPreferencesByModule.v1 | Machine/module bindings; require reassignment |
| AppState/NetworkServiceController | SelectedInternetModule.v1, CellDock.modemNetworkServiceRecord, CellDockInitialSetupCompleted.v1 | Exclude; rebuild |
| IncomingCallWindowController | window origin | Exclude display-specific placement |
| AppIdentityMigration | identity migration markers | Exclude; target owns migration history |
| SystemContactStore | macOS Contacts | No application file to migrate; reauthorize target |
| LaunchAtLoginController | LaunchAgents and registration | Exclude system integration; reauthorize target |
| ModuleVoiceRuntime / eSIM | bundled payloads, module firmware, SIM profiles | Exclude; never write modem during restore |
| Cache/backups/logs/temp | waveform caches, playback mixes, Backups, staging, app archives | Exclude |

Any unclassified new preference stays excluded until explicitly reviewed. Missing portable preferences reset to app defaults; credential absence is distinct from empty content.
