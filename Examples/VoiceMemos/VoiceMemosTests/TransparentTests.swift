//
//  TransparentTests.swift
//  VoiceMemosTests
//
//  Created by Rob Chatfield on 10/9/20.
//  Copyright © 2020 Point-Free. All rights reserved.
//

@testable import VoiceMemos
import XCTest

struct TestStore<State, Effect: EffectProtocol> {
  var state: State
  let reducer: Reducer<State, Effect>
  let environment: Effect.Environment
  
  init(
    initialState: State,
    reducer: Reducer<State, Effect>,
    environment: Effect.Environment
  ) {
    self.state = initialState
    self.reducer = reducer
    self.environment = environment
  }
}

extension TestStore {
  
  @discardableResult
  func assert(
    action: Effect.Action,
    state expectedMutation: (inout State) -> Void,
    effects: [Effect],
    file: StaticString = #file,
    line: UInt = #line
  ) -> Self {
    var expectedState = state
    var actualState = state
    
    expectedMutation(&expectedState)
    let actualEffects = reducer(&actualState, action)
    
    var expectedStateDesc = ""
    dump(expectedState, to: &expectedStateDesc)
    var actualStateDesc = ""
    dump(actualState, to: &actualStateDesc)
    XCTAssertEqual(expectedStateDesc, actualStateDesc, file: file, line: line)
    
    var expectedEffectsDesc = ""
    dump(effects, to: &expectedEffectsDesc)
    var actualEffectsDesc = ""
    dump(actualEffects, to: &actualEffectsDesc)
    XCTAssertEqual(expectedEffectsDesc, actualEffectsDesc, file: file, line: line)
    
    return TestStore(
      initialState: expectedState,
      reducer: reducer,
      environment: environment
    )
  }
}
