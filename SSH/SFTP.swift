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
import BlinkFiles
import LibSSH


public enum FileError: Error {
  case Fail(msg: String)
  
  var description: String {
    switch self {
    case .Fail(let msg):
      return msg
    }
  }
}

extension FileError {
  init(in session: ssh_session) {
    let msg = SSHError.getErrorDescription(session)
    self = .Fail(msg: msg)
  }
  
  init(title: String, in session: ssh_session) {
    let msg = SSHError.getErrorDescription(session)
    self = .Fail(msg: "\(title) - \(msg)")
  }
}

public class SFTPClient : BlinkFiles.Translator {
  let session: ssh_session
  var rootPath: String = ""
  var path: String = ""
  public var current: String { get { path }}
  let sftp: sftp_session
  let rloop: RunLoop
  let channel: ssh_channel
  public private(set) var fileType: FileAttributeType = .typeUnknown
  public var isDirectory: Bool {
    get { return fileType == .typeDirectory }
  }
  
  init(from base: SFTPClient) {
    self.session = base.session
    self.rootPath = base.rootPath
    self.path = base.path
    self.sftp = base.sftp
    self.rloop = base.rloop
    self.channel = base.channel
    self.fileType = base.fileType
  }
  
  init?(on channel: ssh_channel, client: SSHClient) {
    self.session = client.session
    self.channel = channel
    
    guard let sftp = sftp_new_channel(client.session, channel) else {
      return nil
    }
    
    self.sftp = sftp
    self.rloop = RunLoop.current
  }
  
  func start() throws {
    let rc = sftp_init(sftp)
    if rc != SSH_OK {
      throw SSHError(rc, forSession: session)
    }
    
    let (rootPath, fileType) = try self.canonicalize("")
    
    self.rootPath = rootPath
    self.fileType = fileType
    self.path = rootPath
  }
  
  func connection() -> AnyPublisher<sftp_session, Error> {
    return Just(sftp).subscribe(on: rloop).setFailureType(to: Error.self)
      .eraseToAnyPublisher()
  }
  
  func canonicalize(_ path: String) throws -> (String, FileAttributeType) {
    guard let canonicalPath = sftp_canonicalize_path(sftp, path.cString(using: .utf8)) else {
      throw FileError(title: "Could not canonicalize path", in: session)
    }
    
    // Early protocol versions did not stat the item, so we do it ourselves.
    // A path like /tmp/notexist would not fail if whatever does not exist.
    guard let attrsPtr = sftp_stat(sftp, canonicalPath) else {
      throw FileError(title:"\(String(cString:canonicalPath)) No such file or directory.", in: session)
    }
    
    let attrs = attrsPtr.pointee
    var type: FileAttributeType = .typeUnknown
    
    if attrs.type == SSH_FILEXFER_TYPE_DIRECTORY {
      guard let dir = sftp_opendir(sftp, canonicalPath) else {
        throw FileError(title: "No permission.", in: session)
      }
      if sftp_closedir(dir) != 0 {
        throw FileError(title: "Could not close directory.", in: session)
      }
      type = .typeDirectory
    } else if attrs.type == SSH_FILEXFER_TYPE_REGULAR {
      type = .typeRegular
    }
    
    return (String(cString: canonicalPath), type)
  }
  
  public func clone() -> Translator {
    return SFTPClient(from: self)
  }
  
  // Resolve to an element in the hierarchy
  public func walkTo(_ path: String) -> AnyPublisher<Translator, Error> {
    // All paths on SFTP, even Windows ones, must start with a slash (/c:/whatever/)
    var absPath = path
    if !absPath.starts(with: "/") {
      // NSString performs a cleanup of the path as well.
      absPath = NSString(string: self.path).appendingPathComponent(path)
    }
    
    return connection().trySFTP { sftp -> SFTPClient in
      let (canonicalPath, type) = try self.canonicalize(absPath)
      
      self.path = canonicalPath
      self.fileType = type
      
      return self
    }
  }
  
  public func directoryFilesAndAttributes() -> AnyPublisher<[FileAttributes], Error> {
    if fileType != .typeDirectory {
      return Fail(error: FileError(title: "Not a directory.", in: session)).eraseToAnyPublisher()
    }
    
    return connection().trySFTP { sftp -> [FileAttributes] in
      var contents: [FileAttributes] = []
      
      guard let dir = sftp_opendir(sftp, self.path) else {
        throw FileError(in: self.session)
      }
      
      while let pointer = sftp_readdir(sftp, dir) {
        let sftpAttrs = pointer.pointee
        let attrs = self.parseItemAttributes(sftpAttrs)
        
        contents.append(attrs)
        sftp_attributes_free(pointer)
      }
      
      if sftp_closedir(dir) != 0 {
        throw FileError(in: self.session)
      }
      
      return contents
    }
  }
  
  public func open(flags: Int32) -> AnyPublisher<File, Error> {
    if fileType != .typeRegular {
      return Fail(error: FileError(title: "Not a file.", in: session)).eraseToAnyPublisher()
    }
    
    return connection().trySFTP { sftp -> SFTPFile in
      guard let file = sftp_open(sftp, self.path, flags, S_IRWXU) else {
        throw(FileError(title: "Error opening file", in: self.session))
      }
      
      return SFTPFile(file, in: self)
    }
  }
  
  public func create(name: String, flags: Int32, mode: mode_t = S_IRWXU) -> AnyPublisher<BlinkFiles.File, Error> {
    if fileType != .typeDirectory {
      return Fail(error: FileError(title: "Not a directory.", in: session)).eraseToAnyPublisher()
    }
    
    return connection().trySFTP { sftp -> SFTPFile in
      let filePath = (self.path as NSString).appendingPathComponent(name)
      guard let file = sftp_open(sftp, filePath, flags | O_CREAT, mode) else {
        throw FileError(in: self.session)
      }
      
      return SFTPFile(file, in: self)
    }
  }
  
  public func remove() -> AnyPublisher<Bool, Error> {
    return connection().trySFTP { sftp -> Bool in
      let rc = sftp_unlink(sftp, self.path)
      if rc != SSH_OK {
        throw FileError(title: "Could not delete file", in: self.session)
      }
      
      return true
    }
  }
  
  public func rmdir() -> AnyPublisher<Bool, Error> {
    return connection().trySFTP { sftp -> Bool in
      let rc = sftp_rmdir(sftp, self.path)
      if rc != SSH_OK {
        throw FileError(title: "Could not delete directory", in: self.session)
      }
      
      return true
    }
  }
  
  // Mode uses same default as mkdir
  // This is working well for filesystems, but everything else...
  public func mkdir(name: String, mode: mode_t = S_IRWXU | S_IRWXG | S_IRWXO) -> AnyPublisher<Translator, Error> {
    return connection().trySFTP { sftp -> Translator in
      let dirPath = (self.path as NSString).appendingPathComponent(name)
      
      let rc = sftp_mkdir(sftp, dirPath, mode)
      if rc != SSH_OK {
        throw FileError(title: "Could not create directory", in: self.session)
      }
      
      self.path = dirPath
      return self
    }
  }
  
  // Change attributes
  public func stat() -> AnyPublisher<FileAttributes, Error> {
    return connection().trySFTP { sftp -> FileAttributes in
      let p = sftp_stat(sftp, self.path)
      guard let attrs = p?.pointee else {
        throw FileError(title: "Could not stat file", in: self.session)
      }
      
      return self.parseItemAttributes(attrs)
    }
  }
  
  public func wstat(_ attrs: FileAttributes) -> AnyPublisher<Bool, Error> {
    return connection().trySFTP { sftp in
      var sftpAttrs = self.buildItemAttributes(attrs)
      let rc = sftp_setstat(sftp, self.path, &sftpAttrs)
      if rc != SSH_OK {
        throw FileError(title: "Could not setstat file", in: self.session)
      }
      
      return true
    }
  }
  
  func parseItemAttributes(_ attrs: sftp_attributes_struct) -> FileAttributes {
    var item: FileAttributes = [:]
    
    switch attrs.type {
    case UInt8(SSH_FILEXFER_TYPE_REGULAR):
      item[.type] = FileAttributeType.typeRegular
    case UInt8(SSH_FILEXFER_TYPE_SPECIAL):
      item[.type] = FileAttributeType.typeBlockSpecial
    case UInt8(SSH_FILEXFER_TYPE_SYMLINK):
      item[.type] = FileAttributeType.typeSymbolicLink
    case UInt8(SSH_FILEXFER_TYPE_DIRECTORY):
      item[.type] = FileAttributeType.typeDirectory
    default:
      item[.type] = FileAttributeType.typeUnknown
    }
    
    item[.name] = attrs.name != nil ? String(cString: attrs.name, encoding: .utf8) : (self.path as NSString).lastPathComponent
    
    item[.size] = attrs.size != nil ? NSNumber(value: attrs.size) : nil
    
    // Get rid of the upper 4 bits (which are the file type)
    item[.posixPermissions] = Int16(attrs.permissions & 0x0FFF)
    
    return item
  }
  
  func buildItemAttributes(_ attrs: [FileAttributeKey: Any]) -> sftp_attributes_struct {
    var item = sftp_attributes_struct()
    
    switch attrs[.type] as! FileAttributeType {
    case .typeRegular:
      item.type = UInt8(SSH_FILEXFER_TYPE_REGULAR)
    case .typeDirectory:
      item.type = UInt8(SSH_FILEXFER_TYPE_DIRECTORY)
    default:
      item.type = UInt8(SSH_FILEXFER_TYPE_UNKNOWN)
    }
    
    return item
  }
}

public class SFTPFile : BlinkFiles.File {
  let file: sftp_file
  let client: SFTPClient
  let session: ssh_session
  let rloop: RunLoop
  let channel: ssh_channel
  
  var inflightReads: [UInt32] = []
  var inflightWrites: [UInt32] = []
  let blockSize = 32 * 1024
  let maxConcurrentOps = 20
  var demand: Subscribers.Demand = .none
  var pub = PassthroughSubject<DispatchData, Error>()
  
  init(_ file: sftp_file, in client: SFTPClient) {
    self.client = client
    self.file = file
    self.session = client.session
    self.rloop = client.rloop
    self.channel = client.channel
    
    sftp_file_set_nonblocking(file)
  }
  
  public func close() -> AnyPublisher<Bool, Error> {
    return client.connection().trySFTP { _ in
      let rc = sftp_close(self.file)
      
      if rc != SSH_OK {
        throw FileError(title: "Error closing file", in: self.session)
      }
      return true
    }.eraseToAnyPublisher()
  }
}

extension SFTPFile: BlinkFiles.Reader, BlinkFiles.WriterTo {
  public func read(max length: Int) -> AnyPublisher<DispatchData, Error> {
    inflightReads = []
    pub = PassthroughSubject<DispatchData, Error>()
    
    return pub.handleEvents(
      receiveRequest: { (req) in
        // none, unlimited, one
        self.demand = req
        self.rloop.perform { self.inflightReadsLoop() }
      }
    ).reduce(DispatchData.empty, { prevValue, newValue -> DispatchData in
      var n = prevValue
      n.append(newValue)
      return n
    })
    .subscribe(on: rloop)
    .eraseToAnyPublisher()
  }
  
  public func writeTo(_ w: Writer) -> AnyPublisher<Int, Error> {
    inflightReads = []
    pub = PassthroughSubject<DispatchData, Error>()
    
    return pub.handleEvents(
      receiveRequest: { (req) in
        //print("demand")
        self.rloop.perform {
          //print("processing demand")
          self.demand = req
          self.inflightReadsLoop()
        }
      }
    )
    .flatMap(maxPublishers: .max(1)) { data -> AnyPublisher<Int, Error> in
      return w.write(data, max: data.count)
    }
    .eraseToAnyPublisher()
  }
  
  func inflightReadsLoop() {
    // Handle demand. Read scheduled blocks if they are available and push them.
    if inflightReads.count > 0 {
      var data: DispatchData
      var isComplete = false
      
      do {
        (data, isComplete) = try self.readBlocks()
      } catch {
        pub.send(completion: .failure(error))
        return
      }
      
      if data.count > 0 {
        pub.send(data)
        // TODO Account for demand here
        if self.demand != .unlimited {
          self.demand = .none
        }
      }
      
      if isComplete {
        pub.send(completion: .finished)
        return
      }
    }
    
    // Schedule more blocks to read. This way data will already be ready when we come back.
    while inflightReads.count < self.maxConcurrentOps {
      let asyncRequest = sftp_async_read_begin(self.file, UInt32(self.blockSize))
      if asyncRequest < 0 {
        pub.send(completion: .failure(FileError(title: "Could not pre-alloc request file", in: session)))
        return
      }
      inflightReads.append(UInt32(asyncRequest))
    }
    
    // Enqueue again if there is still demand.
    if self.demand != .none {
      rloop.schedule(after: .init(Date(timeIntervalSinceNow: 0.001))) {
        self.inflightReadsLoop()
      }
    }
  }
  
  
  func readBlocks() throws -> (DispatchData, Bool) {
    var data = DispatchData.empty
    var newReads: [UInt32] = []
    
    var lastIdx = -1
    //print("Reading blocks starting from \(inflightReads[0])")
    for (idx, block) in inflightReads.enumerated() {
      let buf = UnsafeMutableRawPointer.allocate(byteCount: self.blockSize, alignment: MemoryLayout<UInt8>.alignment)
      //print("Reading \(block)")
      let nbytes = sftp_async_read(self.file, buf, UInt32(self.blockSize), block)
      if nbytes > 0 {
        let bb = DispatchData(bytesNoCopy: UnsafeRawBufferPointer(start: buf, count: Int(nbytes)),
                              deallocator: .custom(nil, { buf.deallocate() }))
        data.append(bb)
        
        lastIdx = idx
      } else if nbytes == SSH_AGAIN {
        //print("AGAIN")
        break
      } else if nbytes < 0 {
        throw FileError(title: "Error while reading blocks", in: session)
      } else if nbytes == 0 {
        inflightReads = []
        return (data, true)
      }
    }
    
    let blocksRead = lastIdx == -1 ? 0 : lastIdx + 1
    print("Blocks read \(blocksRead), size \(data.count), last block \(lastIdx == -1 ? 0 : inflightReads[lastIdx])")
    inflightReads = Array(inflightReads[blocksRead...])
    inflightReads += newReads
    
    return (data, false)
  }
}

extension SFTPFile: BlinkFiles.Writer {
  // TODO Take into account length
  public func write(_ buf: DispatchData, max length: Int) -> AnyPublisher<Int, Error> {
    let pb = PassthroughSubject<Int, Error>()
    
    func writeLoop(_ w: DispatchData, _ wn: DispatchData) {
      var writtenBytes = 0
      
      var write = w
      var written = wn
      var isFinished = false
      
      if inflightWrites.count > 0 {
        // Check scheduled writes
        do {
          let blocksWritten = try self.checkWrites()
          // The last block has the size of whatever is left, and cannot be
          // accounted with blocks.
          if w.count == 0 && blocksWritten == inflightWrites.count {
            writtenBytes = written.count
            isFinished = true
          } else {
            writtenBytes = blocksWritten * blockSize
          }
          if writtenBytes > 0 {
            // Move buffers
            inflightWrites = Array(inflightWrites[blocksWritten...])
            written = written.subdata(in: writtenBytes..<written.count)
          }
        } catch {
          pub.send(completion: .failure(error))
        }
      }
      
      // Schedule more writes
      while inflightWrites.count < self.maxConcurrentOps && write.count > 0 {
        var asyncRequest: UInt32 = 0
        let length = write.count < self.blockSize ? write.count : self.blockSize
        
        // Check if we can write, otherwise the async write will fail
        if ssh_channel_window_size(self.channel) < length {
          break
        }
        
        let rc = write.withUnsafeBytes { bytes -> Int32 in
          return sftp_async_write(self.file, bytes, length, &asyncRequest)
        }
        
        if rc != SSH_OK {
          pb.send(completion: .failure(FileError(title: "Could not pre-alloc write request", in: session)))
          return
        }
        
        inflightWrites.append(asyncRequest)
        write = write.subdata(in: length..<write.count)
      }
      
      if writtenBytes > 0 {
        // Publish bytes written
        pb.send(writtenBytes)
      }
      
      if isFinished {
        pb.send(completion: .finished)
      } else {
        rloop.schedule { writeLoop(write, written) }
      }
    }
    
    
    return pb.handleEvents(receiveRequest: { _ in self.rloop.perform { writeLoop(buf, buf) } })
      .eraseToAnyPublisher()
  }
  
  func checkWrites() throws -> Int {
    var lastIdx = 0
    
    for block in inflightWrites {
      let rc = sftp_async_write_end(self.file, block, 0)
      if rc == SSH_AGAIN {
        break
      } else if rc != SSH_OK {
        throw FileError(title: "Error while writing block", in: session)
      }
      lastIdx += 1
    }
    
    return lastIdx
  }
}
