import Foundation

public enum MediaCategory: String {
  /// The category for video media attached to Tweets
  case tweetVideo = "tweet_video"
  
  /// The category for images attached to Tweets
  case tweetImage = "tweet_image"
  
  /// The category for gifs attached to Tweets
  case tweetGif = "tweet_gif"
}

extension Twift {
  // MARK: Media Upload v2

  public func uploadMediaV2(mediaData: Data,
                            mimeType: String,
                            category: MediaCategory,
                            chunkSize: Int = 4 * 1024 * 1024) async throws -> MediaUploadV2Response {
    try await performMediaUploadV2(totalBytes: mediaData.count,
                                   mimeType: mimeType,
                                   category: category) { mediaId in
      try await self.appendMediaChunksV2(mediaId: mediaId,
                                         data: mediaData,
                                         chunkSize: chunkSize)
    }
  }

  public func uploadMediaV2(fileURL: URL,
                            mimeType: String,
                            category: MediaCategory,
                            chunkSize: Int = 4 * 1024 * 1024) async throws -> MediaUploadV2Response {
    let totalBytes = try totalBytesForMedia(fileURL: fileURL)
    return try await performMediaUploadV2(totalBytes: totalBytes,
                                          mimeType: mimeType,
                                          category: category) { mediaId in
      try await self.appendMediaChunksV2(mediaId: mediaId,
                                         fileURL: fileURL,
                                         chunkSize: chunkSize)
    }
  }

  fileprivate func performMediaUploadV2(totalBytes: Int,
                                        mimeType: String,
                                        category: MediaCategory,
                                        chunkUploader: (Media.ID) async throws -> Void) async throws -> MediaUploadV2Response {
    guard totalBytes > 0 else {
      throw TwiftError.UnknownError("Media upload requires data with a positive length.")
    }

    if case .oauth2UserAuth(_, _) = self.authenticationType {
      try await refreshOAuth2AccessToken()
    }

    let initResponse = try await initializeMediaUploadV2(totalBytes: totalBytes,
                                                         mimeType: mimeType,
                                                         category: category)
    let mediaId = initResponse.data.id

    try await chunkUploader(mediaId)

    let finalizeResponse = try await finalizeMediaUploadV2(mediaId: mediaId)
    return try await waitForProcessingIfNeeded(mediaId: mediaId, startingWith: finalizeResponse)
  }

  fileprivate func initializeMediaUploadV2(totalBytes: Int,
                                           mimeType: String,
                                           category: MediaCategory) async throws -> MediaUploadV2Response {
    let queryItems = [
      URLQueryItem(name: "command", value: "INIT"),
      URLQueryItem(name: "media_type", value: mimeType),
      URLQueryItem(name: "total_bytes", value: "\(totalBytes)"),
      URLQueryItem(name: "media_category", value: category.rawValue)
    ]

    return try await call(route: .mediaUpload,
                          method: .POST,
                          queryItems: queryItems)
  }

  fileprivate func finalizeMediaUploadV2(mediaId: Media.ID) async throws -> MediaUploadV2Response {
    let queryItems = [
      URLQueryItem(name: "command", value: "FINALIZE"),
      URLQueryItem(name: "media_id", value: mediaId)
    ]

    return try await call(route: .mediaUpload,
                          method: .POST,
                          queryItems: queryItems)
  }

  fileprivate func mediaUploadStatusV2(mediaId: Media.ID) async throws -> MediaUploadV2Response {
    let queryItems = [
      URLQueryItem(name: "command", value: "STATUS"),
      URLQueryItem(name: "media_id", value: mediaId)
    ]

    return try await call(route: .mediaUpload,
                          method: .GET,
                          queryItems: queryItems)
  }

  fileprivate func waitForProcessingIfNeeded(mediaId: Media.ID,
                                             startingWith response: MediaUploadV2Response) async throws -> MediaUploadV2Response {
    var latestResponse = response

    while let processingInfo = latestResponse.data.processingInfo {
      switch processingInfo.state {
      case .succeeded:
        return latestResponse
      case .failed:
        let errorMessage = processingInfo.error?.message ?? "Media processing failed."
        throw TwiftError.UnknownError(errorMessage)
      case .pending, .inProgress:
        let waitSeconds = UInt64(max(processingInfo.checkAfterSecs ?? 1, 1))
        try await Task.sleep(nanoseconds: waitSeconds * 1_000_000_000)
        latestResponse = try await mediaUploadStatusV2(mediaId: mediaId)
      }
    }

    return latestResponse
  }

  fileprivate func appendMediaChunksV2(mediaId: Media.ID,
                                       data: Data,
                                       chunkSize: Int) async throws {
    guard data.count > 0 else { return }
    let chunkSize = max(chunkSize, 1)
    var offset = 0
    var segmentIndex = 0

    while offset < data.count {
      let end = min(offset + chunkSize, data.count)
      let chunk = data.subdata(in: offset..<end)
      try await appendMediaChunkV2(mediaId: mediaId,
                                   chunk: chunk,
                                   segmentIndex: segmentIndex)
      offset = end
      segmentIndex += 1
    }
  }

  fileprivate func appendMediaChunksV2(mediaId: Media.ID,
                                       fileURL: URL,
                                       chunkSize: Int) async throws {
    let chunkSize = max(chunkSize, 1)
    let fileHandle = try FileHandle(forReadingFrom: fileURL)
    defer { try? fileHandle.close() }

    var segmentIndex = 0
    while true {
      let chunk: Data = autoreleasepool(invoking: {
        fileHandle.readData(ofLength: chunkSize)
      })

      if chunk.isEmpty {
        break
      }

      try await appendMediaChunkV2(mediaId: mediaId,
                                   chunk: chunk,
                                   segmentIndex: segmentIndex)
      segmentIndex += 1
    }
  }

  fileprivate func appendMediaChunkV2(mediaId: Media.ID,
                                      chunk: Data,
                                      segmentIndex: Int) async throws {
    guard !chunk.isEmpty else { return }

    let url = getURL(for: .mediaUpload)
    var request = URLRequest(url: url)
    let boundary = "Boundary-\(UUID().uuidString)"
    request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()
    appendFormField(name: "command", value: "APPEND", to: &body, boundary: boundary)
    appendFormField(name: "media_id", value: mediaId, to: &body, boundary: boundary)
    appendFormField(name: "segment_index", value: "\(segmentIndex)", to: &body, boundary: boundary)
    appendFileField(name: "media", filename: "chunk", contentType: "application/octet-stream", data: chunk, to: &body, boundary: boundary)
    body.appendString("--\(boundary)--\r\n")

    request.httpBody = body

    signURLRequest(method: .POST, body: body, request: &request)

    let (_, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse,
          (200...299).contains(httpResponse.statusCode) else {
      throw TwiftError.UnknownError(response)
    }
  }

  fileprivate func totalBytesForMedia(fileURL: URL) throws -> Int {
    if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
       let fileSize = resourceValues.fileSize {
      return fileSize
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    if let sizeNumber = attributes[.size] as? NSNumber {
      return Int(truncating: sizeNumber)
    }
    if let sizeValue = attributes[.size] as? Int {
      return sizeValue
    }

    throw TwiftError.UnknownError("Unable to determine file size for media upload.")
  }

  // MARK: Chunked Media Upload (Legacy)
  /// Uploads media data and returns an ID string that can be used to attach media to Tweets
  /// - Warning: This method relies on Twitter's v1.1 media API endpoints and only supports OAuth 1.0a authentication.
  /// - Parameters:
  ///   - mediaData: The media data to upload
  ///   - mimeType: The type of media you're uploading
  ///   - category: The category for the media you're uploading. Defaults to `tweetImage`; this will cause gif and video uploads to error unless the category is set appropriately.
  ///   - progress: An optional pointer to a `Progress` instance, used to track the progress of the upload task.
  ///   The progress is based on the number of base64 chunks the data is split into; each chunk will be approximately 2mb in size.
  /// - Returns: A ``MediaUploadResponse`` object containing information about the uploaded media, including its `mediaIdString`, which is used to attach media to Tweets
  @available(*, deprecated, message: "Media methods currently depend on OAuth 1.0a authentication, which will be deprecated in a future version of Twift. These media methods may be removed or replaced in the future.")
  public func upload(mediaData: Data, mimeType: String, category: MediaCategory, progress: UnsafeMutablePointer<Progress>? = nil) async throws -> MediaUploadResponse {
    let initializeResponse = try await initializeUpload(data: mediaData, mimeType: mimeType)
    try await appendMediaChunks(mediaKey: initializeResponse.mediaIdString, data: mediaData, progress: progress)
    return try await finalizeUpload(mediaKey: initializeResponse.mediaIdString)
  }
  
  /// Allows the user to provide alt text for the `mediaId`. This feature is currently only supported for images and GIFs.
  ///
  /// Usage:
  /// 1. Upload media using the `upload(mediaData)` method
  /// 2. Add alt text to the `mediaId` returned from step 1 via this method
  /// 3. Create a Tweet with the `mediaId`
  /// - Warning: This method relies on Twitter's v1.1 media API endpoints and only supports OAuth 1.0a authentication.
  /// - Parameters:
  ///   - mediaId: The target media to attach alt text to
  ///   - text: The alt text to attach to the `mediaId`
  @available(*, deprecated, message: "Media methods currently depend on OAuth 1.0a authentication, which will be deprecated in a future version of Twift. These media methods may be removed or replaced in the future.")
  public func addAltText(to mediaId: Media.ID, text: String) async throws {
    guard case .userAccessTokens(let clientCredentials, let userCredentials) = self.authenticationType else {
      throw TwiftError.WrongAuthenticationType(needs: .userAccessTokens)
    }
    
    let body: [String: Any] = [
      "media_id": mediaId,
      "alt_text": [
        "text": text
      ]
    ]
    
    let encodedBody = try JSONSerialization.data(withJSONObject: body)
    
    let url = getURL(for: .mediaMetadataCreate)
    var request = URLRequest(url: url)
    
    request.oAuthSign(method: "POST",
                      body: encodedBody,
                      contentType: "application/json",
                      consumerCredentials: clientCredentials,
                      userCredentials: userCredentials)
    
    let (_, response) = try await URLSession.shared.data(for: request)
    
    guard let response = response as? HTTPURLResponse,
          response.statusCode >= 200 && response.statusCode < 300 else {
            throw TwiftError.UnknownError(response)
          }
  }
  
  /// Checks to see whether the `mediaId` has finished processing successfully. This method will wait for the `GET /1.1/media/upload.json?command=STATUS` endpoint to return either `succeeded` or `failed`; for large videos, this may take some time.
  /// - Parameter mediaId: The media ID to check the upload status of
  /// - Returns: A `Bool` indicating whether the media has uploaded successfully (`true`) or not (`false`).
  @available(*, deprecated, message: "Media methods currently depend on OAuth 1.0a authentication, which will be deprecated in a future version of Twift. These media methods may be removed or replaced in the future.")
  public func checkMediaUploadSuccessful(_ mediaId: Media.ID) async throws -> Bool {
    var urlComponents = baseMediaURLComponents()
    urlComponents.queryItems = [
      URLQueryItem(name: "command", value: "STATUS"),
      URLQueryItem(name: "media_id", value: mediaId)
    ]
    let url = urlComponents.url!
    var request = URLRequest(url: url)
    
    signURLRequest(method: .GET, request: &request)
    
    let isWaiting = true
    
    while isWaiting {
      let (processingStatus, _) = try await URLSession.shared.data(for: request)
      let status = try decoder.decode(MediaUploadResponse.self, from: processingStatus)
      
      guard let state = status.processingInfo?.state else {
        return false
      }
      
      switch state {
      case .pending:
        break
      case .inProgress:
        break
      case .failed:
        return false
      case .succeeded:
        return true
      }
      
      if let waitPeriod = status.processingInfo?.checkAfterSecs {
        try await Task.sleep(nanoseconds: UInt64(waitPeriod * 1_000_000_000))
      }
    }
  }
}

extension Twift {
  // MARK: Media Helper Methods
  @available(*, deprecated, message: "Media methods currently depend on OAuth 1.0a authentication, which will be deprecated in a future version of Twift. These media methods may be removed or replaced in the future.")
  fileprivate func initializeUpload(data: Data, mimeType: String) async throws -> MediaInitResponse {
    guard case .userAccessTokens(let clientCredentials, let userCredentials) = self.authenticationType else {
      throw TwiftError.WrongAuthenticationType(needs: .userAccessTokens)
    }
    
    let url = baseMediaURLComponents().url!
    var initRequest = URLRequest(url: url)
    
    let body = [
      "command": "INIT",
      "media_type": mimeType,
      "total_bytes": "\(data.count)"
    ]
    
    initRequest.oAuthSign(method: "POST",
                          urlFormParameters: body,
                          consumerCredentials: clientCredentials,
                          userCredentials: userCredentials)
    
    let (requestData, _) = try await URLSession.shared.data(for: initRequest)
    
    return try decoder.decode(MediaInitResponse.self, from: requestData)
  }
  
  fileprivate func appendMediaChunks(mediaKey: String, data: Data, progress: UnsafeMutablePointer<Progress>? = nil) async throws {
    guard case .userAccessTokens(let clientCredentials, let userCredentials) = self.authenticationType else {
      throw TwiftError.OAuthTokenError
    }
    
    let dataEncodedAsBase64Strings = chunkData(data)
    
    progress?.pointee.fileTotalCount = dataEncodedAsBase64Strings.count
    var completed = 0
    
    for chunk in dataEncodedAsBase64Strings {
      let index = dataEncodedAsBase64Strings.firstIndex(of: chunk)!
      
      let body = [
        "command": "APPEND",
        "media_id": mediaKey,
        "media_data": chunk,
        "segment_index": "\(index)"
      ]
      
      let url = baseMediaURLComponents().url!
      var appendRequest = URLRequest(url: url)
      
      appendRequest.addValue("base64", forHTTPHeaderField: "Content-Transfer-Encoding")
      
      appendRequest.oAuthSign(method: "POST",
                              urlFormParameters: body,
                              consumerCredentials: clientCredentials,
                              userCredentials: userCredentials)
      
      let (_, response) = try await URLSession.shared.data(for: appendRequest)
      
      guard let response = response as? HTTPURLResponse,
            response.statusCode >= 200 && response.statusCode < 300 else {
              throw TwiftError.UnknownError(response)
            }
      
      completed += 1
      DispatchQueue.main.async { [completed] in
        progress?.pointee.fileCompletedCount = completed
      }
    }
  }
  
  fileprivate func finalizeUpload(mediaKey: String) async throws -> MediaUploadResponse {
    guard case .userAccessTokens(let clientCredentials, let userCredentials) = self.authenticationType else {
      throw TwiftError.OAuthTokenError
    }
    
    let body = [
      "command": "FINALIZE",
      "media_id": mediaKey,
    ]
    
    let url = baseMediaURLComponents().url!
    var finalizeRequest = URLRequest(url: url)
    
    finalizeRequest.oAuthSign(method: "POST",
                              urlFormParameters: body,
                              consumerCredentials: clientCredentials,
                              userCredentials: userCredentials)
    
    let (finalizeResponseData, _) = try await URLSession.shared.data(for: finalizeRequest)
    
    return try decodeOrThrow(decodingType: MediaUploadResponse.self, data: finalizeResponseData)
  }
  
  fileprivate func baseMediaURLComponents() -> URLComponents {
    var urlComponents = URLComponents()
    urlComponents.host = "upload.twitter.com"
    urlComponents.path = "/1.1/media/upload.json"
    urlComponents.scheme = "https"
    
    return urlComponents
  }
}

fileprivate func chunkData(_ data: Data) -> [String] {
  let dataLen = data.count
  let chunkSize = ((1024 * 1000) * 2) // MB
  let fullChunks = Int(dataLen / chunkSize)
  let totalChunks = fullChunks + (dataLen % 1024 != 0 ? 1 : 0)
  
  var chunks: [Data] = []
  for chunkCounter in 0..<totalChunks {
    var chunk: Data
    let chunkBase = chunkCounter * chunkSize
    var diff = chunkSize
    if(chunkCounter == totalChunks - 1) {
      diff = dataLen - chunkBase
    }
    
    let range:Range<Data.Index> = (chunkBase..<(chunkBase + diff))
    chunk = data.subdata(in: range)
    chunks.append(chunk)
  }
  
  return chunks.map { $0.base64EncodedString() }
}

fileprivate struct MediaInitResponse: Codable {
  let mediaId: Int
  let mediaIdString: String
  let expiresAfterSecs: Int
}

/// A response object containing information about the uploaded media
public struct MediaUploadResponse: Codable {
  /// The uploaded media's unique Integer ID
  public let mediaId: Int
  
  /// The uploaded media's ID represented as a `String`. The string representation of the ID is preferred for ensuring precision.
  public let mediaIdString: String
  
  /// The size of the uploaded media
  public let size: Int?
  
  /// When this media upload will expire, if not attached to a Tweet
  public let expiresAfterSecs: Int?
  
  /// Information about the media's processing status. Most images are processed instantly, but large gifs and videos may take longer to process before they can be used in a Tweet.
  ///
  /// Use the ``Twift.checkMediaUploadSuccessful()`` method to wait until the media is successfully processed.
  public let processingInfo: MediaProcessingInfo?
  
  /// An object containing information about the media's processing status.
  public struct MediaProcessingInfo: Codable {
    /// The current processing state of the media
    public let state: State
    
    /// How many seconds the user is advised to wait before checking the status of the media again
    public let checkAfterSecs: Int?
    
    /// The percent completion of the media processing
    public let progressPercent: Int?
    
    /// Any errors that caused the media processing to fail
    public let error: ProcessingError?
    
    public enum State: String, Codable {
      /// The media is queued to be processed
      case pending
      
      /// The media is currently being processed
      case inProgress = "in_progress"
      
      /// The media could not be processed
      case failed
      
      /// The media was successfully processed and is ready to be attached to a Tweet
      case succeeded
    }
    
    /// An error associated with media processing
    public struct ProcessingError: Codable {
      /// The status code for this error
      public let code: Int
      
      /// The name of the error
      public let name: String
      
      /// A longer description of the processing error
      public let message: String?
    }
  }
}

/// A response object representing uploads performed via the v2 media endpoint
public struct MediaUploadV2Response: Codable {
  public struct Payload: Codable {
    public let id: Media.ID
    public let mediaKey: Media.ID?
    public let expiresAfterSecs: Int?
    public let processingInfo: ProcessingInfo?
  }

  public struct ProcessingInfo: Codable {
    public enum State: String, Codable {
      case pending
      case inProgress = "in_progress"
      case failed
      case succeeded
    }

    public struct ProcessingError: Codable {
      public let code: Int?
      public let name: String?
      public let message: String?
    }

    public let state: State
    public let checkAfterSecs: Int?
    public let progressPercent: Int?
    public let error: ProcessingError?
  }

  public let data: Payload
}

fileprivate extension Data {
  mutating func appendString(_ string: String) {
    if let stringData = string.data(using: .utf8) {
      append(stringData)
    }
  }
}

fileprivate func appendFormField(name: String, value: String, to body: inout Data, boundary: String) {
  body.appendString("--\(boundary)\r\n")
  body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
  body.appendString("\(value)\r\n")
}

fileprivate func appendFileField(name: String,
                                 filename: String,
                                 contentType: String,
                                 data: Data,
                                 to body: inout Data,
                                 boundary: String) {
  body.appendString("--\(boundary)\r\n")
  body.appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
  body.appendString("Content-Type: \(contentType)\r\n\r\n")
  body.append(data)
  body.appendString("\r\n")
}
