import SwiftUI

struct MiniRecorderView: View {
    @ObservedObject var whisperState: WhisperState
    @ObservedObject var recorder: Recorder
    @EnvironmentObject var windowManager: MiniWindowManager
    @EnvironmentObject private var enhancementService: AIEnhancementService

    @State private var activePopover: ActivePopoverState = .none
    @State private var isHovered: Bool = false

    // MARK: - Design Constants
    private let collapsedWidth: CGFloat = 120
    private let expandedWidth: CGFloat = 200
    private let mainContentHeight: CGFloat = 30

    private var pillWidth: CGFloat {
        isHovered ? expandedWidth : collapsedWidth
    }

    private var isRecording: Bool {
        whisperState.recordingState == .recording
    }

    private var contentLayout: some View {
        HStack(spacing: 0) {
            if isHovered {
                RecorderPromptButton(
                    activePopover: $activePopover,
                    buttonSize: 20,
                    padding: EdgeInsets()
                )
                .padding(.leading, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.5)))
            }

            Spacer(minLength: 0)

            RecorderStatusDisplay(
                currentState: whisperState.recordingState,
                audioMeter: recorder.audioMeter
            )

            Spacer(minLength: 0)

            if isHovered {
                RecorderPowerModeButton(
                    activePopover: $activePopover,
                    buttonSize: 20,
                    padding: EdgeInsets()
                )
                .padding(.trailing, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.5)))
            }
        }
        .frame(height: mainContentHeight)
    }

    var body: some View {
        if windowManager.isVisible {
            contentLayout
                .frame(width: pillWidth)
                .background(.ultraThinMaterial)
                .preferredColorScheme(.dark)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.blue.opacity(isRecording ? 0.4 : 0.0), lineWidth: 1)
                )
                .onHover { hovering in
                    isHovered = hovering
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isHovered)
                .animation(.easeInOut(duration: 0.3), value: isRecording)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

