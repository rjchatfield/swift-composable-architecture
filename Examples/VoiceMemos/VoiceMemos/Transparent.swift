//
//  Transparent.swift
//  VoiceMemos
//
//  Created by Rob Chatfield on 10/9/20.
//  Copyright © 2020 Point-Free. All rights reserved.
//

import Combine
import Foundation

import ComposableArchitecture

// To help bridging from TCA, we'll use their effects rather than AnyPublisher
public typealias ActionPublisher<T> = ComposableArchitecture.Effect<T, Never>

public protocol EffectProtocol {
    associatedtype Action
    associatedtype Environment
    
    func callAsFunction(_ environment: Environment) -> ActionPublisher<Action>
}

public struct Reducer<State, Effect> where Effect: EffectProtocol {
    public let reduce: (inout State, Effect.Action) -> [Effect]
    
    public init(reduce: @escaping (inout State, Effect.Action) -> [Effect]) {
        self.reduce = reduce
    }
    
    public func callAsFunction(_ state: inout State, _ action: Effect.Action) -> [Effect] {
        self.reduce(&state, action)
    }
}

extension Reducer {
  public func eraseToAnyEffect() -> Reducer<State, AnyEffect<Effect.Action, Effect.Environment>> {
    Reducer<State, AnyEffect<Effect.Action, Effect.Environment>> { state, action in
      self(&state, action)
        .map { $0.eraseToAnyEffect() }
    }
  }
  
  public func forEach<GlobalState, GlobalAction, GlobalEnvironment, ID>(
    state toLocalState: WritableKeyPath<GlobalState, IdentifiedArray<ID, State>>,
    action toLocalAction: CasePath<GlobalAction, (ID, Effect.Action)>,
    environment toLocalEnvironment: @escaping (GlobalEnvironment) -> Effect.Environment
  ) -> Reducer<GlobalState, AnyEffect<GlobalAction, GlobalEnvironment>> {
    Reducer<GlobalState, AnyEffect<GlobalAction, GlobalEnvironment>> { globalState, globalAction in
      guard let (id, localAction) = toLocalAction.extract(from: globalAction) else { return [] }

      // This does not need to be a fatal error because of the unwrap that follows it.
      assert(globalState[keyPath: toLocalState][id: id] != nil)

      return self(&globalState[keyPath: toLocalState][id: id]!, localAction)
        .map {
          $0.pullback(environment: toLocalEnvironment)
            .pullback(action: { toLocalAction.embed((id, $0)) })
        }
    }
  }
  
//  public func forEach<GlobalState, GlobalAction, GlobalEnvironment>(
//    state toLocalState: WritableKeyPath<GlobalState, [State]>,
//    action toLocalAction: CasePath<GlobalAction, (Int, Effect.Action)>,
//    environment toLocalEnvironment: @escaping (GlobalEnvironment) -> Effect.Environment
//  ) -> Reducer<GlobalState, AnyEffect<GlobalAction, GlobalEnvironment>> {
//    Reducer<GlobalState, AnyEffect<GlobalAction, GlobalEnvironment>> { globalState, globalAction in
//      guard let (index, localAction) = toLocalAction.extract(from: globalAction) else {
//        return []
//      }
//      // NB: This does not need to be a fatal error because of the index subscript that follows it.
//      assert(index < globalState[keyPath: toLocalState].endIndex)
//
//      return self(&globalState[keyPath: toLocalState][index], localAction)
//        .map {
//          $0.pullback(environment: toLocalEnvironment)
//            .pullback(action: { toLocalAction.embed((index, $0)) })
//        }
//    }
//  }
  
  public func forEach<GlobalState, GlobalEffect>(
    state toLocalState: WritableKeyPath<GlobalState, [State]>,
    action toLocalAction: CasePath<GlobalEffect.Action, (Int, Effect.Action)>,
    effect toGlobalEffect: @escaping (Int, Effect) -> GlobalEffect
  ) -> Reducer<GlobalState, GlobalEffect> {
    Reducer<GlobalState, GlobalEffect> { globalState, globalAction in
      guard let (index, localAction) = toLocalAction.extract(from: globalAction) else {
        return []
      }
      // NB: This does not need to be a fatal error because of the index subscript that follows it.
      assert(index < globalState[keyPath: toLocalState].endIndex)
      
      return self(&globalState[keyPath: toLocalState][index], localAction)
        .map { toGlobalEffect(index, $0) }
    }
  }

}

public struct AnyEffect<Action, Environment>: EffectProtocol {
    private let run: (_ environment: Environment) -> ActionPublisher<Action>

    public init<Effect: EffectProtocol>(_ effect: Effect) where Effect.Action == Action, Effect.Environment == Environment {
        self.run = effect.callAsFunction
    }

    public init(_ run: @escaping (_ environment: Environment) -> ActionPublisher<Action>) {
        self.run = run
    }

    public func callAsFunction(_ environment: Environment) -> ActionPublisher<Action> {
        run(environment)
    }
}

extension EffectProtocol {

    public func eraseToAnyEffect() -> AnyEffect<Action, Environment> {
        AnyEffect(self)
    }
  
  public func pullback<GlobalEnvironment>(
    environment toLocalEnvironment: @escaping (GlobalEnvironment) -> Environment
  ) -> AnyEffect<Action, GlobalEnvironment> {
    AnyEffect<Action, GlobalEnvironment> { (globalEnv: GlobalEnvironment) -> ActionPublisher<Action> in
      self(toLocalEnvironment(globalEnv))
    }
  }
  
  public func pullback<GlobalAction>(
    action toGlobalAction: @escaping (Action) -> GlobalAction
  ) -> AnyEffect<GlobalAction, Environment> {
    AnyEffect<GlobalAction, Environment> { env in
      self(env).map(toGlobalAction)
    }
  }
}

extension Reducer {

    public func pullback<SuperState, SuperAction, SuperEnvironment>(
        subState subStateKeyPath: WritableKeyPath<SuperState, State>,
        subAction subActionKeyPath: WritableKeyPath<SuperAction, Effect.Action?>,
        subEnvironment subEnvironmentKeyPath: KeyPath<SuperEnvironment, Effect.Environment>
    ) -> Reducer<SuperState, AnyEffect<SuperAction, SuperEnvironment>> {
        .init { superState, superAction in
            guard let subAction = superAction[keyPath: subActionKeyPath] else {
                return []
            }

            return self(&superState[keyPath: subStateKeyPath], subAction).map { effect in
                AnyEffect<SuperAction, SuperEnvironment> { environment in
                    effect(environment[keyPath: subEnvironmentKeyPath])
                        .map { action in
                            var superAction = superAction
                            superAction[keyPath: subActionKeyPath] = action
                            return superAction
                        }
                        .eraseToEffect()
                }
            }
        }
    }
}

@dynamicMemberLookup
public final class Store<State, Action>: ObservableObject {
    @Published public private(set) var state: State

    private let actionsSubject = PassthroughSubject<Action, Never>()
    private var effectsCancellable: Cancellable?
    private var scopeCancellable: Cancellable?
    
    public subscript<Value>(dynamicMember keyPath: KeyPath<State, Value>) -> Value {
        state[keyPath: keyPath]
    }

    public init<Effect>(
        initialState: State,
        reducer: Reducer<State, Effect>,
        environment: Effect.Environment
    ) where Effect: EffectProtocol, Action == Effect.Action {
        self.state = initialState

        self.effectsCancellable = actionsSubject
            .compactMap { [weak self] action in
                self.map({ reducer(&$0.state, action) })?.map({ $0(environment) })
            }
            .flatMap(Publishers.MergeMany.init)
            // (1) State modification should happen on main,
            // (2) PassthroughSubject is not thread safe
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                self?.send(action)
            }
    }

    public func send(_ action: Action) {
        actionsSubject.send(action)
    }
}

extension Store {

    public func scope<SubState, SubAction>(
        subState subStateKeyPath: KeyPath<State, SubState>,
        toSuperAction: @escaping (SubAction) -> Action
    ) -> Store<SubState, SubAction> where SubState: Equatable {
        let subReducer = Reducer<SubState, AnyEffect<SubAction, Void>> { subState, subAction in
            self.send(toSuperAction(subAction))
            subState = self.state[keyPath: subStateKeyPath]
            return []
        }

        let subStore = Store<SubState, SubAction>(
            initialState: state[keyPath: subStateKeyPath],
            reducer: subReducer,
            environment: ()
        )

        subStore.scopeCancellable = $state
            .map(subStateKeyPath)
            .removeDuplicates()
            .sink { [weak subStore] state in
                subStore?.state = state
            }

        return subStore
    }
}

// MARK: - Added from TCA

import SwiftUI

extension Store {
  public func binding<LocalState>(
    get: @escaping (State) -> LocalState,
    send localStateToViewAction: @escaping (LocalState) -> Action
  ) -> Binding<LocalState> {
    Binding(
      get: { get(self.state) },
      set: { newLocalState, transaction in
        withAnimation(transaction.disablesAnimations ? nil : transaction.animation) {
          self.send(localStateToViewAction(newLocalState))
        }
      })
  }
}

extension Reducer {
//  public static func combine<E, A>(_ reducers: [Reducer]) -> Reducer where Effect == AnyEffect<E, A> {
//    Self { value, action in
//      reducers
//        .flatMap { $0(&value, action) }
//        .map { $0.eraseToAnyEffect() }
//    }
//  }
//  public static func combine<E, A>(_ reducers: Reducer...) -> Reducer where Effect == AnyEffect<E, A> {
//    .combine(reducers)
//  }
  public static func combine(_ reducers: [Reducer]) -> Reducer {
    Self { value, action in
      reducers.flatMap { $0(&value, action) }
    }
  }
  public static func combine(_ reducers: Reducer...) -> Reducer {
    .combine(reducers)
  }
}

func WithViewStore<State, Action, ContentView: View>(
  _ store: Store<State, Action>,
  content: (Store<State, Action>) -> ContentView
) -> ContentView {
  content(store)
}

//// A structure that computes views on demand from a store on a collection of data.
//public struct ForEachStore<EachState, EachAction, Data, ID, Content>: DynamicViewContent
//where Data: Collection, ID: Hashable, Content: View {
//  public let data: Data
//  private let content: () -> Content
//
//  /// Initializes a structure that computes views on demand from a store on an array of data and an
//  /// indexed action.
//  ///
//  /// - Parameters:
//  ///   - store: A store on an array of data and an indexed action.
//  ///   - id: A key path identifying an element.
//  ///   - content: A function that can generate content given a store of an element.
//  public init<EachContent>(
//    _ store: Store<Data, (Data.Index, EachAction)>,
//    id: KeyPath<EachState, ID>,
//    content: @escaping (Store<EachState, EachAction>) -> EachContent
//  )
//  where
//    Data == [EachState],
//    EachContent: View,
//    Content == ForEach<ContiguousArray<(Data.Index, EachState)>, ID, EachContent>
//    ForEach<ContiguousArray<(Range<Array<EachState>.Index>.Element, EachState)>, ID, EmptyView>
//  {
//    self.data = store.state
//    let f = ForEach(
//      ContiguousArray(zip(store.indices, store.state)),
//      id: (\(Data.Index, EachState).1).appending(path: id)
//    ) { index, element in
//      EmptyView()
////      content(
////        store.scope(
////          state: { index < $0.endIndex ? $0[index] : element },
////          action: { (index, $0) }
////        )
////      )
//    }
//    self.content = { fatalError() }
//  }
//
//////  /// Initializes a structure that computes views on demand from a store on an array of data and an
//////  /// indexed action.
//////  ///
//////  /// - Parameters:
//////  ///   - store: A store on an array of data and an indexed action.
//////  ///   - content: A function that can generate content given a store of an element.
//////  public init<EachContent>(
//////    _ store: Store<Data, (Data.Index, EachAction)>,
//////    content: @escaping (Store<EachState, EachAction>) -> EachContent
//////  )
//////  where
//////    Data == [EachState],
//////    EachContent: View,
//////    Content == WithViewStore<
//////      Data, (Data.Index, EachAction),
//////      ForEach<ContiguousArray<(Data.Index, EachState)>, ID, EachContent>
//////    >,
//////    EachState: Identifiable,
//////    EachState.ID == ID
//////  {
//////    self.init(store, id: \.id, content: content)
//////  }
////
//////  /// Initializes a structure that computes views on demand from a store on a collection of data and
//////  /// an identified action.
//////  ///
//////  /// - Parameters:
//////  ///   - store: A store on an identified array of data and an identified action.
//////  ///   - content: A function that can generate content given a store of an element.
//////  public init<EachContent: View>(
//////    _ store: Store<IdentifiedArray<ID, EachState>, (ID, EachAction)>,
//////    content: @escaping (Store<EachState, EachAction>) -> EachContent
//////  )
//////  where
//////    EachContent: View,
//////    Data == IdentifiedArray<ID, EachState>,
//////    Content == WithViewStore<
//////      IdentifiedArray<ID, EachState>, (ID, EachAction),
//////      ForEach<IdentifiedArray<ID, EachState>, ID, EachContent>
//////    >
//////  {
//////
//////    self.data = ViewStore(store, removeDuplicates: { _, _ in false }).state
//////    self.content = {
//////      WithViewStore(
//////        store,
//////        removeDuplicates: { lhs, rhs in
//////          guard lhs.id == rhs.id else { return false }
//////          guard lhs.count == rhs.count else { return false }
//////          return zip(lhs, rhs).allSatisfy { $0[keyPath: lhs.id] == $1[keyPath: rhs.id] }
//////        }
//////      ) { viewStore in
//////        ForEach(viewStore.state, id: viewStore.id) { element in
//////          content(
//////            store.scope(
//////              state: { $0[id: element[keyPath: viewStore.id]] ?? element },
//////              action: { (element[keyPath: viewStore.id], $0) }
//////            )
//////          )
//////        }
//////      }
//////    }
//
//  public var body: some View {
//    self.content()
//  }
//}
