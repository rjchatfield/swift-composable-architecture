import AVFoundation
import ComposableArchitecture
import SwiftUI

struct VoiceMemosState: Equatable {
  var alert: AlertState<VoiceMemosAction>?
  var audioRecorderPermission = RecorderPermission.undetermined
  var currentRecording: CurrentRecording?
  var voiceMemos: [VoiceMemo] = []

  struct CurrentRecording: Equatable {
    var date: Date
    var duration: TimeInterval = 0
    var mode: Mode = .recording
    var url: URL

    enum Mode {
      case recording
      case encoding
    }
  }

  enum RecorderPermission {
    case allowed
    case denied
    case undetermined
  }
}

enum VoiceMemosAction: Equatable {
  case alertDismissed
  case audioRecorderClient(Result<AudioRecorderClient.Action, AudioRecorderClient.Failure>)
  case currentRecordingTimerUpdated
  case finalRecordingTime(TimeInterval)
  case openSettingsButtonTapped
  case recordButtonTapped
  case recordPermissionBlockCalled(Bool)
  case voiceMemo(index: Int, action: VoiceMemoAction)
  
  case _new_setState_currentRecording(VoiceMemosState.CurrentRecording)
}

struct VoiceMemosEnvironment {
  var audioPlayerClient: AudioPlayerClient
  var audioRecorderClient: AudioRecorderClient
  var date: () -> Date
  var mainQueue: AnySchedulerOf<DispatchQueue>
  var openSettings: Effect<Never, Never>
  var temporaryDirectory: () -> URL
  var uuid: () -> UUID
}

enum VoiceMemosEffect: EffectProtocol {
  
  case cancel
  case openSettings
  case requestRecordPermission
  case startRecording
  case stop
  case voiceMemo(index: Int, effect: VoiceMemoEffect)
  
  func callAsFunction(_ environment: VoiceMemosEnvironment) -> ActionPublisher<VoiceMemosAction> {
    
    struct RecorderId: Hashable {}
    struct RecorderTimerId: Hashable {}

    switch self {
    case .cancel:
      return .cancel(id: RecorderTimerId())
    case .openSettings:
      return environment.openSettings
        .fireAndForget()
    case .requestRecordPermission:
      return environment.audioRecorderClient.requestRecordPermission()
        .map(VoiceMemosAction.recordPermissionBlockCalled)
        .receive(on: environment.mainQueue)
        .eraseToEffect()
    case .startRecording:
      let url = environment.temporaryDirectory()
        .appendingPathComponent(environment.uuid().uuidString)
        .appendingPathExtension("m4a")
      return .merge(
        .init(value: ._new_setState_currentRecording(.init(
          date: environment.date(),
          url: url
        ))),
        environment.audioRecorderClient.startRecording(RecorderId(), url)
          .catchToEffect()
          .map(VoiceMemosAction.audioRecorderClient),
        Effect.timer(id: RecorderTimerId(), every: 1, tolerance: .zero, on: environment.mainQueue)
          .map { _ in .currentRecordingTimerUpdated }
      )
    case .stop:
      return .concatenate(
        .cancel(id: RecorderTimerId()),
        environment.audioRecorderClient.currentTime(RecorderId())
          .compactMap { $0 }
          .map(VoiceMemosAction.finalRecordingTime)
          .eraseToEffect(),
        environment.audioRecorderClient.stopRecording(RecorderId())
          .fireAndForget()
      )
    case .voiceMemo(let index, let effect):
      let subEnv = VoiceMemoEnvironment(
        audioPlayerClient: environment.audioPlayerClient,
        mainQueue: environment.mainQueue
      )
      return effect(subEnv)
        .map { .voiceMemo(index: index, action: $0) }
    }
  }
}

let voiceMemosReducer = Reducer<VoiceMemosState, VoiceMemosEffect>.combine(
  voiceMemoReducer.forEach(
    state: \.voiceMemos,
    action: /VoiceMemosAction.voiceMemo(index:action:),
    effect: VoiceMemosEffect.voiceMemo(index:effect:)
  ),
  Reducer<VoiceMemosState, VoiceMemosEffect> { state, action in
    switch action {
    case .alertDismissed:
      state.alert = nil
      return []

    case .audioRecorderClient(.success(.didFinishRecording(successfully: true))):
      guard
        let currentRecording = state.currentRecording,
        currentRecording.mode == .encoding
      else {
        assertionFailure()
        return []
      }

      state.currentRecording = nil
      state.voiceMemos.insert(
        VoiceMemo(
          date: currentRecording.date,
          duration: currentRecording.duration,
          url: currentRecording.url
        ),
        at: 0
      )
      return []

    case .audioRecorderClient(.success(.didFinishRecording(successfully: false))),
      .audioRecorderClient(.failure):
      state.alert = .init(title: "Voice memo recording failed.")
      state.currentRecording = nil
      return [.cancel]

    case .currentRecordingTimerUpdated:
      state.currentRecording?.duration += 1
      return []

    case let .finalRecordingTime(duration):
      state.currentRecording?.duration = duration
      return []

    case .openSettingsButtonTapped:
      return [.openSettings]

    case .recordButtonTapped:
      switch state.audioRecorderPermission {
      case .undetermined:
        return [.requestRecordPermission]

      case .denied:
        state.alert = .init(title: "Permission is required to record voice memos.")
        return []

      case .allowed:
        guard let currentRecording = state.currentRecording else {
          return [.startRecording]
        }

        switch currentRecording.mode {
        case .encoding:
          return []

        case .recording:
          state.currentRecording?.mode = .encoding
          return [.stop]
        }
      }

    case let .recordPermissionBlockCalled(permission):
      state.audioRecorderPermission = permission ? .allowed : .denied
      if permission {
        return [.startRecording]
      } else {
        state.alert = .init(title: "Permission is required to record voice memos.")
        return []
      }

    case .voiceMemo(index: _, action: .audioPlayerClient(.failure)):
      state.alert = .init(title: "Voice memo playback failed.")
      return []

    case let .voiceMemo(index: index, action: .delete):
      state.voiceMemos.remove(at: index)
      return []

    case let .voiceMemo(index: index, action: .playButtonTapped):
      for idx in state.voiceMemos.indices where idx != index {
        state.voiceMemos[idx].mode = .notPlaying
      }
      return []

    case .voiceMemo:
      return []
      
    case ._new_setState_currentRecording(let currentRecording):
      state.currentRecording = currentRecording
      return []
    }
  }
)

struct VoiceMemosView: View {
  let store: Store<VoiceMemosState, VoiceMemosAction>

  var body: some View {
      NavigationView {
        VStack {
//          List {
//            ForEachStore(
//              self.store.scope(
//                state: { $0.voiceMemos }, action: VoiceMemosAction.voiceMemo(index:action:)
//              ),
//              id: \.url,
//              content: VoiceMemoView.init(store:)
//            )
//            .onDelete { indexSet in
//              for index in indexSet {
//                store.send(.voiceMemo(index: index, action: .delete))
//              }
//            }
//          }
          VStack {
            ZStack {
              Circle()
                .foregroundColor(.black)
                .frame(width: 74, height: 74)

              Button(action: { self.store.send(.recordButtonTapped) }) {
                RoundedRectangle(cornerRadius: store.currentRecording != nil ? 4 : 35)
                  .foregroundColor(.red)
                  .padding(store.currentRecording != nil ? 17 : 2)
                  .animation(.spring())
              }
              .frame(width: 70, height: 70)

              if store.state.audioRecorderPermission == .denied {
                VStack(spacing: 10) {
                  Text("Recording requires microphone access.")
                    .multilineTextAlignment(.center)
                  Button("Open Settings") { self.store.send(.openSettingsButtonTapped) }
                }
                .frame(maxWidth: .infinity, maxHeight: 74)
                .background(Color.white.opacity(0.9))
              }
            }

            (store.currentRecording?.duration).map { duration in
              dateComponentsFormatter.string(from: duration).map {
                Text($0)
                  .font(Font.body.monospacedDigit().bold())
                  .foregroundColor(.white)
                  .colorMultiply(Int(duration).isMultiple(of: 2) ? .red : .black)
                  .animation(.easeInOut(duration: 0.5))
              }
            }
          }
          .padding()
          .animation(Animation.easeInOut(duration: 0.3))
        }
//        .alert(
//          self.store.scope(state: { $0.alert }),
//          dismiss: .alertDismissed
//        )
        .navigationBarTitle("Voice memos")
      }
      .navigationViewStyle(StackNavigationViewStyle())
    }
}

struct VoiceMemos_Previews: PreviewProvider {
  static var previews: some View {
    VoiceMemosView(
      store: Store(
        initialState: VoiceMemosState(
          voiceMemos: [
            VoiceMemo(
              date: Date(),
              duration: 30,
              mode: .playing(progress: 0.3),
              title: "Functions",
              url: URL(string: "https://www.pointfree.co/functions")!
            ),
            VoiceMemo(
              date: Date(),
              duration: 2,
              mode: .notPlaying,
              title: "",
              url: URL(string: "https://www.pointfree.co/untitled")!
            ),
          ]
        ),
        reducer: voiceMemosReducer,
        environment: VoiceMemosEnvironment(
          audioPlayerClient: .live,
          // NB: AVAudioRecorder doesn't work in previews, so we stub out the dependency here.
          audioRecorderClient: .init(
            currentTime: { _ in Effect(value: 10) },
            requestRecordPermission: { Effect(value: true) },
            startRecording: { _, _ in .none },
            stopRecording: { _ in .none }
          ),
          date: Date.init,
          mainQueue: DispatchQueue.main.eraseToAnyScheduler(),
          openSettings: .none,
          temporaryDirectory: { URL(fileURLWithPath: NSTemporaryDirectory()) },
          uuid: UUID.init
        )
      )
    )
  }
}
