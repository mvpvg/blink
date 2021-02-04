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

import Combine
import Foundation
import LibSSH


public protocol AuthMethod {
  // Standard name used to compare the auth method with the available ones from the server.
  func name() -> String
}

protocol Authenticator: AuthMethod {
  func auth(_ conn: SSHConnection) -> AnyPublisher<AuthState, Error>
}

public enum AuthState {
  case Success
  case Denied
  case Continue(auth: AnyPublisher<AuthState, Error>)
  case Partial
}

// MARK: Password Authentication Method

public class AuthPassword: AuthMethod, Authenticator {
  let password: String
  
  public init(with password: String) {
    self.password = password
  }
  
  func auth(_ session: ssh_session) throws -> AuthState {
    let rc = ssh_userauth_password(session, nil, password)
    
    switch rc {
    case SSH_AUTH_SUCCESS.rawValue:
      return .Success
    case SSH_AUTH_DENIED.rawValue:
      return .Denied
    case SSH_AUTH_PARTIAL.rawValue:
      return .Partial
    case SSH_AUTH_AGAIN.rawValue:
      throw SSHError(auth: ssh_auth_e(rawValue: rc), forSession: session)
    default:
      throw SSHError(auth: ssh_auth_e(rawValue: rc), forSession: session)
    }
  }
  
  func auth(_ conn: SSHConnection) -> AnyPublisher<AuthState, Error> {
    return conn.tryAuth { try self.auth($0) }
  }
  
  public func name() -> String {
    return "password"
  }
}

// MARK: None Authentication Method

/// This method allows to get the available authentication methods. It also gives the server a chance to authenticate the user with just
/// his/her login. Some old hardware use this feature to fallback the user on a "telnet over SSH" style of login.
public class AuthNone: AuthMethod, Authenticator {
  
  public init() {
    
  }
  
  func auth(_ session: ssh_session) throws -> AuthState {
    let rc = ssh_userauth_none(session, nil)
    
    switch rc {
    case SSH_AUTH_SUCCESS.rawValue:
      return .Success
    case SSH_AUTH_DENIED.rawValue:
      return .Denied
    default:
      throw SSHError(auth: ssh_auth_e(rawValue: rc), forSession: session)
    }
  }
  
  internal func auth(_ connection: SSHConnection) -> AnyPublisher<AuthState, Error> {
    return connection.tryAuth { try self.auth($0) }
  }
  
  public func name() -> String {
    return "none"
  }
}

// MARK: Keyboard Interactive Authentication Method

public struct Prompt {
  public let name: String
  public let instruction: String
  public struct Question {
    public let prompt: String
    public let echo: Bool
  }
  
  public var userPrompts: [Question]
}

// Try Authentication in phases. So you can return the state of the authentication,
// and whether or not there is another step or phase that needs to be called right after.
// Let TryAuth understand Success or Denied, and let it work through the details in
// case it needs to do something else.
public class AuthKeyboardInteractive: AuthMethod, Authenticator {
  public typealias RequestAnswersCb = (Prompt) -> AnyPublisher<[String], Error>
  
  let requestAnswers: RequestAnswersCb
  
  /// Authentication will be tried this number of times prior to failing.
  /// If there are retries left it returns a `SSH_AUTH_AGAIN`
  var wrongRetriesLeft: Int = 2
  
  public init(requestAnswers f: @escaping RequestAnswersCb, wrongRetriesAllowed: Int = 3) {
    self.requestAnswers = f
    
    self.wrongRetriesLeft = wrongRetriesAllowed
  }
  
  func auth(_ conn: SSHConnection) -> AnyPublisher<AuthState, Error> {
    return conn.tryAuth { session in
      let rc = ssh_userauth_kbdint(session, nil, nil)
      switch rc {
      case SSH_AUTH_SUCCESS.rawValue:
        return .Success
      case SSH_AUTH_PARTIAL.rawValue:
        return .Partial
      case SSH_AUTH_DENIED.rawValue:
        
        self.wrongRetriesLeft -= 1
        
        if self.wrongRetriesLeft >= 0 {
          throw SSHError(auth: SSH_AUTH_AGAIN, forSession: session)
        }
        
        return .Denied
      case SSH_AUTH_INFO.rawValue:
        // Get prompt info
        let p = self.prompts(session)
        
        return AuthState.Continue(
          auth: self.requestAnswers(p)
            .tryMap { answers in
              _ = try answers.enumerated().map { (idx, answer) in
                
                let str = answer.cString(using: .utf8)
                let rc = ssh_userauth_kbdint_setanswer(session, UInt32(idx), str)
                
                if rc < 0 {
                  throw SSHError(rc, forSession: session)
                }
              }
              return conn
            }
            // We need to loop, as we may receive questions in multiple phases.
            .flatMap { self.auth($0) }
            .eraseToAnyPublisher()
        )
      default:
        throw SSHError(auth: ssh_auth_e(rawValue: rc), forSession: session)
      }
    }
  }
  
  func prompts(_ session: ssh_session) -> Prompt {
    let name = ssh_userauth_kbdint_getname(session)
    let instruction = ssh_userauth_kbdint_getinstruction(session)
    let nprompts = ssh_userauth_kbdint_getnprompts(session)
    
    var userPrompts: [Prompt.Question] = []
    
    
    _ = (0..<nprompts).map { n in
      var echo: CChar = 0
      
      let prompt = ssh_userauth_kbdint_getprompt(session, UInt32(n), &echo)
      let userPrompt = Prompt.Question(prompt: String(cString: prompt!), echo: (echo > 0 ? true : false))
      
      userPrompts.append(userPrompt)
    }
    
    return Prompt(name: String(cString: name!),
                  instruction: String(cString: instruction!),
                  userPrompts: userPrompts)
  }
  
  public func name() -> String {
    return "keyboard-interactive"
  }
}

// MARK: Public Key Authentication Method


/**
 Steps to authenticate with public key:
 
 1. Retrieve the public key with either `ssh_pki_import_pubkey_file()` or `ssh_pki_import_pubkey_base64()`
 2. Offer the **public key** to the SSH server using `ssh_userauth_try_publickey()`. It it returns `SSH_AUTH_SUCCESS` the SSH server accepts to authenticate using the public key.
 3. Retrieve the private key using either `ssh_pki_import_privkey_file`or `ssh_pki_import_privkey_base64`. If a passphrase is required either it's needed as an argument or a callback.
 4. Authenticate using `ssh_userauth_publickey()` with your private key
 5. Clean up memory using `ssh_key_free()`
 */
public class AuthPublicKey: AuthMethod, Authenticator {
  
  let privateKey: String
  var key: ssh_key?
  // Blink only works with no passphrase keys
  // let callback: ssh_auth_callback?
  
  // Constructor from a String already, we assume content is obtained somewhere else.
  public init(privateKey: String) {
    // We could import here, but prefer to do it somewhere else outside the configuration.
    self.privateKey = privateKey
  }
  
  func publicKeyNegotiation(_ session: ssh_session) throws -> AuthState {
    try importPrivateKey()
    
    let rc = ssh_userauth_try_publickey(session, nil, self.key)
    
    switch rc {
    case SSH_AUTH_SUCCESS.rawValue:
      return .Success
    case SSH_AUTH_PARTIAL.rawValue:
      return .Partial
    case SSH_AUTH_DENIED.rawValue:
      return .Denied
    default:
      throw SSHError(auth: ssh_auth_e(rc), forSession: session)
    }
  }
  
  func importPrivateKey() throws {
    let pKey = privateKey.cString(using: .utf8)
    let rc = ssh_pki_import_privkey_base64(pKey, nil, nil, nil, &self.key)
    
    if rc == SSH_ERROR {
      throw SSHError(auth: ssh_auth_e(rc), forSession: nil, message: "Error importing key")
    }
  }
  
  func privateKeyAuthentication(_ session: ssh_session) throws -> AuthState {
    let rc = ssh_userauth_publickey(session, nil, self.key)
    
    switch rc {
    case SSH_AUTH_SUCCESS.rawValue:
      return .Success
    /// You've been partially authenticated, you still have to use another method
    case SSH_AUTH_PARTIAL.rawValue:
      return .Partial
    case SSH_AUTH_DENIED.rawValue:
      return .Denied
    default:
      throw SSHError(auth: ssh_auth_e(rc), forSession: session)
    }
  }
  
  func auth(_ conn: SSHConnection) -> AnyPublisher<AuthState, Error> {
    return conn.tryAuth { session in
      let state = try self.publicKeyNegotiation(session)
      switch state {
      case .Success:
        return AuthState.Continue(auth: conn.tryAuth { try self.privateKeyAuthentication($0) })
      default:
        return state
      }
    }
  }
  
  public func name() -> String {
    return "publickey"
  }
  
  deinit {
    if let key = key {
      ssh_key_free(key)
    }
  }
}