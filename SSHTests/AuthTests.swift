//////////////////////////////////////////////////////////////////////////////////
//
// B L I N K
//
// Copyright (C) 2016-2021 Blink Mobile Shell Project
//
// This file is part of Blink.
//
// Blink is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Blink is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Blink. If not, see <http://www.gnu.org/licenses/>.
//
// In addition, Blink is also subject to certain additional terms under
// GNU GPL version 3 section 7.
//
// You should have received a copy of these additional terms immediately
// following the terms and conditions of the GNU General Public License
// which accompanied the Blink Source Code. If not, see
// <http://www.github.com/blinksh/blink>.
//
////////////////////////////////////////////////////////////////////////////////

import XCTest
import Combine
import Dispatch

@testable import SSH

struct Credentials {
  let user: String
  let password: String
  let host: String
}

class AuthTests: XCTestCase {
  var cancellableBag = Set<AnyCancellable>()
  
  override func setUpWithError() throws {
    // Put setup code here. This method is called before the invocation of each test method in the class.
    SSHInit()
  }
  
  override func tearDownWithError() throws {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    //        fatalError()
  }
  
  override func tearDown() {
    cancellableBag.removeAll()
  }
  
  func testPasswordAuthenticationWithCallback() throws {
    let requestAnswers: SSHClientConfig.RequestVerifyHostCallback = { (prompt) in
      
      return Just(InteractiveResponse.affirmative).setFailureType(to: Error.self).eraseToAnyPublisher()
    }
    
    let config = SSHClientConfig(user: MockCredentials.passwordCredentials.user, authMethods: [AuthPassword(with: MockCredentials.passwordCredentials.password)], verifyHostCallback: requestAnswers)
    
    let expectation = self.expectation(description: "Buffer Written")
    
    var connection: SSHClient?
    SSHClient.dial(MockCredentials.passwordCredentials.host, with: config)
      .sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let error):
          if let error = error as? SSHError {
            XCTFail(error.description)
            break
          }
          XCTFail("Unknown error")
        }
      }, receiveValue: { conn in
        connection = conn
        expectation.fulfill()
      }).store(in: &cancellableBag)
    
    waitForExpectations(timeout: 50, handler: nil)
    
    XCTAssertNotNil(connection)
  }
  
  func testPasswordAuthentication() throws {
    let config = SSHClientConfig(user: "javier", authMethods: [AuthPassword(with: "reivaj123")])
    
    let expectation = self.expectation(description: "Buffer Written")
    
    var connection: SSHClient?
    SSHClient.dial("bips.bi.ehu.eus", with: config)
      .sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let error):
          if let error = error as? SSHError {
            XCTFail(error.description)
            break
          }
          XCTFail("Unknown error")
        }
      }, receiveValue: { conn in
        connection = conn
        
        
        
        expectation.fulfill()
      }).store(in: &cancellableBag)
    
    waitForExpectations(timeout: 5, handler: nil)
    
    XCTAssertNotNil(connection)
  }
  
  /**
   Feed the wrong private key to the test and then continue as normal to test partial authentication.
   */
  func testPartialAuthenticationFailingFirst() throws {
    let config = SSHClientConfig(user: MockCredentials.partialAuthenticationCredentials.user, authMethods: [AuthPublicKey(privateKey: MockCredentials.notCopiedPrivateKey), AuthPassword(with: MockCredentials.partialAuthenticationCredentials.password), AuthPublicKey(privateKey: MockCredentials.privateKey)])
    
    let expectation = self.expectation(description: "Buffer Written")
    
    var connection: SSHClient?
    SSHClient.dial(MockCredentials.partialAuthenticationCredentials.host, with: config)
      .sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let error):
          if let error = error as? SSHError {
            XCTFail(error.description)
            break
          }
          XCTFail("Unknown error")
        }
      }, receiveValue: { conn in
        connection = conn
        expectation.fulfill()
      }).store(in: &cancellableBag)
    
    waitForExpectations(timeout: 10, handler: nil)
    
    XCTAssertNotNil(connection)
  }
  
  
  /**
   Only providing a method of the two needed to authenticate. Should fail as it also need password authentication to be provided.
   */
  func testFailingPartialAuthentication() throws {
    let config = SSHClientConfig(user: MockCredentials.partialAuthenticationCredentials.user, authMethods: [AuthPublicKey(privateKey: MockCredentials.notCopiedPrivateKey)])
    
    let expectation = self.expectation(description: "Buffer Written")
    
    SSHClient.dial(MockCredentials.partialAuthenticationCredentials.host, with: config)
      .sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let error):
          if let error = error as? SSHError {
            
            if case SSHError.authFailed = error {
              expectation.fulfill()
              break
            }
            
            XCTFail("Unknown error")
          }
          
          XCTFail("Unknown error")
        }
      }, receiveValue: { _ in })
      .store(in: &cancellableBag)
    
    waitForExpectations(timeout: 5, handler: nil)
  }
  
  /**
   
   */
  func testPartialAuthentication() throws {
    let config = SSHClientConfig(user: MockCredentials.partialAuthenticationCredentials.user, authMethods: [AuthPublicKey(privateKey: MockCredentials.privateKey), AuthPassword(with: MockCredentials.partialAuthenticationCredentials.password)])
    
    let expectation = self.expectation(description: "Buffer Written")
    
    var connection: SSHClient?
    SSHClient.dial(MockCredentials.partialAuthenticationCredentials.host, with: config)
      .sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let error):
          if let error = error as? SSHError {
            XCTFail(error.description)
            break
          }
          XCTFail("Unknown error")
        }
      }, receiveValue: { conn in
        connection = conn
        expectation.fulfill()
      }).store(in: &cancellableBag)
    
    waitForExpectations(timeout: 10, handler: nil)
    
    XCTAssertNotNil(connection)
  }
  
  // MARK: Wrong credentials
  // This test should fail before the timeout expecation is consumed
  func testFailWithWrongCredentials() throws {
    let config = SSHClientConfig(user: MockCredentials.wrongCredentials.user, authMethods: [AuthPassword(with: MockCredentials.wrongCredentials.password)] )
    
    let expectation = self.expectation(description: "SSH config")
    
    var connection: SSHClient?
    
    SSHClient.dial(MockCredentials.wrongCredentials.host, with: config)
      .sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          XCTFail("Connection succeded for wrong credentials")
        case .failure(let error):
          if let error = error as? SSHError {
            // TODO Assert error is an Auth error
            print(error.description)
            
            // Connection failed, which is what we wanted to test.
            expectation.fulfill()
            break
          }
          XCTFail("Unknown error during connection")
        }
      }, receiveValue: { _ in
        XCTFail("Should not have received a connection")
      })
      .store(in: &cancellableBag)
    
    waitForExpectations(timeout: 10, handler: nil)
  }
  
  // MARK: No authentication methods provided
  
  /**
   Don't provide any authentication methods. Should succeed with a host that has none auth method
   */
  func testEmptyAuthMethods() throws {
    let config = SSHClientConfig(user: MockCredentials.noneCredentials.user, authMethods: [])
    
    let expectation = self.expectation(description: "Buffer Written")
    
    var connection: SSHClient?
    SSHClient.dial(MockCredentials.noneCredentials.host, with: config)
      .sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let error):
          if let error = error as? SSHError {
            XCTFail(error.description)
            break
          }
          XCTFail("Unknown error")
        }
      }, receiveValue: { conn in
        connection = conn
        expectation.fulfill()
      })
      .store(in: &cancellableBag)
    
    waitForExpectations(timeout: 5, handler: nil)
    
    XCTAssertNotNil(connection)
  }
  
  func testNoneAuthentication() throws {
    let config = SSHClientConfig(user: MockCredentials.noneCredentials.user, authMethods: [AuthNone()])
    
    let expectation = self.expectation(description: "Buffer Written")
    
    var connection: SSHClient?
    SSHClient.dial(MockCredentials.noneCredentials.host, with: config)
      .sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let error):
          if let error = error as? SSHError {
            XCTFail(error.description)
            break
          }
          XCTFail("Unknown error")
        }
      }, receiveValue: { conn in
        connection = conn
        expectation.fulfill()
      }).store(in: &cancellableBag)
    
    waitForExpectations(timeout: 5, handler: nil)
    
    XCTAssertNotNil(connection)
  }
  
  /**
   Test first a failing method then a method that succeeds.
   */
  func testFirstFailingThenSucceeding() throws {
    let config = SSHClientConfig(user: MockCredentials.passwordCredentials.user, authMethods: [AuthPassword(with: MockCredentials.wrongCredentials.password), AuthPassword(with: MockCredentials.passwordCredentials.password)])
    
    let expectation = self.expectation(description: "Buffer Written")
    
    var connection: SSHClient?
    SSHClient.dial(MockCredentials.passwordCredentials.host, with: config)
      .sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let error):
          if let error = error as? SSHError {
            XCTFail(error.description)
            break
          }
          XCTFail("Unknown error")
        }
      }, receiveValue: { conn in
        connection = conn
        expectation.fulfill()
      }).store(in: &cancellableBag)
    
    waitForExpectations(timeout: 30, handler: nil)
    
    XCTAssertNotNil(connection)
  }
  
  // MARK: Public Key Authentication
  
  /**
   Should fail when importing a private key `wrongPrivateKey` that's not correctly formatted.
   */
  func testImportingIncorrectPrivateKey() throws {
    
    let config = SSHClientConfig(user: MockCredentials.publicKeyAuthentication.user, authMethods: [AuthPublicKey(privateKey: MockCredentials.wrongPrivateKey)])
    
    let expectation = self.expectation(description: "SSH config")
    
    var connection: SSHClient?
    
    SSHClient.dial(MockCredentials.publicKeyAuthentication.host, with: config)
      .sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let error):
          if let error = error as? SSHError {
            
            if case SSHError.authError = error {
              expectation.fulfill()
              break
            }
            
          }
          
          XCTFail("Unknown error")
          
        }
      }, receiveValue: { conn in
        connection = conn
        expectation.fulfill()
      }).store(in: &cancellableBag)
    
    waitForExpectations(timeout: 10, handler: nil)
  }
  
  func testPubKeyAuthentication() throws {
    
    let config = SSHClientConfig(user: MockCredentials.publicKeyAuthentication.user, authMethods: [AuthPublicKey(privateKey: MockCredentials.privateKey)])
    
    let expectation = self.expectation(description: "SSH config")
    
    var connection: SSHClient?
    
    SSHClient.dial(MockCredentials.publicKeyAuthentication.host, with: config)
      .sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let error):
          if let error = error as? SSHError {
            XCTFail(error.description)
            break
          }
          XCTFail("Unknown error")
        }
      }, receiveValue: { conn in
        connection = conn
        expectation.fulfill()
      }).store(in: &cancellableBag)
    
    waitForExpectations(timeout: 10, handler: nil)
    
    XCTAssertNotNil(connection)
  }
  
  // MARK: Interactive Keyboard Authentication
  func testInteractiveKeyboardAuth() throws {
    var retry = 0
    
    let requestAnswers: AuthKeyboardInteractive.RequestAnswersCb = { (prompt) in
      dump(prompt)
      
      var answers: [String] = []
      
      if prompt.userPrompts.count > 0 {
        // Fail on first retry
        if retry > 0 {
          answers = [MockCredentials.interactiveCredentials.password]
        } else {
          retry += 1
          answers = []
        }
      } else {
        answers = []
      }
      
      return Just(answers).setFailureType(to: Error.self).eraseToAnyPublisher()
    }
    
    let config = SSHClientConfig(user: MockCredentials.interactiveCredentials.user, authMethods: [AuthKeyboardInteractive(requestAnswers: requestAnswers)] )
    
    let expectation = self.expectation(description: "SSH config")
    
    var connection: SSHClient?
    
    SSHClient.dial(MockCredentials.interactiveCredentials.host, with: config)
      .sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let error):
          if let error = error as? SSHError {
            XCTFail(error.description)
            break
          }
          XCTFail("Unknown error")
        }
      }, receiveValue: { conn in
        connection = conn
        expectation.fulfill()
      }).store(in: &cancellableBag)
    
    waitForExpectations(timeout: 500, handler: nil)
    
    XCTAssertNotNil(connection)
  }
}
