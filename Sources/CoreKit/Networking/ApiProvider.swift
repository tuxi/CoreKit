//
//  ApiProvider.swift
//  Chater
//
//  Created by xiaoyuan on 2023/6/11.
//

import Foundation
import Alamofire

public typealias HTTPMethod = Alamofire.HTTPMethod
public typealias RequestInterceptor = Alamofire.RequestInterceptor

public protocol ApiEndpoint: Sendable {
    var baseURL: URL? { get } // 默认 nil，使用 Config 的 baseURL
    var path: String { get }
    var method: HTTPMethod { get }
    var parameters: [String: Sendable] { get }
    var headers: [String: String] { get }
    var encoding: ApiParameterEncoding { get }
}

// 默认实现
public extension ApiEndpoint {
    var baseURL: URL? { nil }
    var headers: [String: String] { [:] }
    var encoding: ApiParameterEncoding { .json }
}


public enum APIError: Error {
    // 服务器空响应
    case noResponse
    // 解码错误
    case decodingError(Error)
    // 网络错误返回AFError
    case networkError(AFError) // 明确使用 AFError
    // 业务场景的错误
    case businessError(code: Int, message: String?)
    // 未知错误
    case unknown(Error)
}

extension APIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noResponse:
            return "Server returned no data."
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .networkError(let error):
            // 提取 Alamofire 更深层的错误信息
            return error.underlyingError?.localizedDescription ?? error.localizedDescription
        case .businessError(_, let message):
            return message ?? "Operation failed with business error."
        case .unknown(let error):
            return error.localizedDescription
        }
    }
}

public enum ApiParameterEncoding {
    case json
    case url
    
    fileprivate var instance: ParameterEncoding {
        switch self {
        case .json:
            return JSONEncoding.default
        case .url:
            return URLEncoding.default
        }
    }
}

/// 网络配置协议：允许不同项目提供不同的公共参数逻辑
public protocol ApiConfiguration: Sendable {
    var baseURL: URL { get }
    var commonHeaders: [String: String] { get }
    var commonParameters: [String: Sendable] { get }
    var timeout: TimeInterval { get }
    var interceptor: RequestInterceptor? { get }
    var decrypter: ApiDecrypter? { get } // 注入解密器
    var isDebugLogEnabled: Bool { get }
}

/// 默认实现
public struct DefaultApiConfiguration: ApiConfiguration {
    public let baseURL: URL
    public var commonHeaders: [String: String] = [:]
    public var commonParameters: [String: Sendable] = [:]
    public var timeout: TimeInterval = 20
    public var interceptor: RequestInterceptor? = nil
    public var decrypter: (any ApiDecrypter)?
    public var isDebugLogEnabled: Bool { true }
    
    public init(baseURL: URL, timeout: TimeInterval) {
        self.baseURL = baseURL
        self.timeout = timeout
    }
}

public struct ApiProvider: Sendable {
    private let config: ApiConfiguration
    private let session: Session
    
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        decoder.dateDecodingStrategy = .formatted(formatter)
        return decoder
    }()

    /// 依赖注入Api 配置 初始化 ApiProvider
    public init(config: ApiConfiguration) {
        self.config = config
        
        let rootSessionConfig = URLSessionConfiguration.af.default
        rootSessionConfig.timeoutIntervalForRequest = config.timeout
        
        // 将日志逻辑作为 EventMonitor 注入 Session
        let logger = NetworkLogger(enabled: config.isDebugLogEnabled)
        
        self.session = Session(
            configuration: rootSessionConfig,
            interceptor: config.interceptor,
            eventMonitors: [logger] // 这里可以放多个监控器，比如埋点监控、日志监控等
        )
    }
   

    ///  异步请求：直接返回 Data Model
   public func request<T: Decodable & Sendable>(endpoint: ApiEndpoint) async throws -> T {
        let response: ApiResponse<T> = try await requestRaw(endpoint: endpoint)
        if let data = response.data {
            return data
        }
        throw APIError.noResponse
    }

    /// 底层请求方法：处理原始 Response
    private func requestRaw<T: Decodable>(endpoint: ApiEndpoint) async throws -> ApiResponse<T> {
        let url = endpoint.baseURL ?? config.baseURL // 允许 Endpoint 覆盖 BaseURL
        let fullURL = url.appendingPathComponent(endpoint.path)
        
        // 合并公共参数与业务参数
        var parameters = config.commonParameters
        endpoint.parameters.forEach { parameters[$0.key] = $0.value }
        
        // 合并 Headers
        var headers = HTTPHeaders(config.commonHeaders)
        endpoint.headers.forEach { headers.add(name: $0.key, value: $0.value) }
        
        // 修正 GET 请求的编码逻辑
        var encoding = endpoint.encoding.instance
        if endpoint.method == .get && endpoint.encoding == .json {
            encoding = URLEncoding.default
        }
        

        // 使用 Alamofire 5.5+ 原生 async 支持
        let dataRequest = session.request(
            fullURL,
            method: endpoint.method,
            parameters: parameters,
            encoding: encoding,
            headers: headers
        )
       
        
        let decoder = self.decoder
        if let decrypter = config.decrypter {
            // 注入到 userInfo，这样 ApiResponse 在 init(from:) 里就能拿到它
            decoder.userInfo[.decrypterKey] = decrypter
        }
        
        let dataTask = dataRequest.serializingDecodable(ApiResponse<T>.self, decoder: decoder)
        do {
            let response = await dataTask.response
            switch response.result {
            case .success(let apiResponse):
                if apiResponse.isSuccess {
                    return apiResponse
                } else {
                    throw APIError.businessError(code: apiResponse.code, message: apiResponse.message)
                }
            case .failure(let error):
                // 区分是解析错误还是网络错误
                if case .responseSerializationFailed = error {
                    throw APIError.decodingError(error)
                }
                throw APIError.networkError(error)
            }
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.unknown(error)
        }
    }
}

extension ApiProvider {
    // 仅限 Package 内部（或测试目标）使用
    init(config: ApiConfiguration, session: Session) {
        self.config = config
        self.session = session
    }
}

/// 解密协议：由具体项目实现
public protocol ApiDecrypter: Sendable {
    func decrypt(_ data: Data) throws -> Data
}


// T 必须同时满足 Decodable 和 Sendable
public struct ApiResponse<T: Decodable & Sendable>: Decodable, Sendable {
    var code: Int
    var message: String?
    var data: T?
    var traceId: String?
    
    // 2. 将 Any? 改为 Data?。Data 是 Sendable 的。
    // 如果你确实需要存储解压/解密后的 Data，Data 类型是最合适的。
    var rawData: Data?
    var isEncrypted = false
    
    var isSuccess: Bool {
        return code == 0 || code == 200
    }
    
    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decode(Int.self, forKey: .code)
        self.message = try container.decodeIfPresent(String.self, forKey: .message)
        self.traceId = try container.decodeIfPresent(String.self, forKey: .traceId)
        self.isEncrypted = (try? container.decode(Bool.self, forKey: .isEncrypted)) ?? false
        
        // 获取外部注入的解密器（通过 decoder.userInfo）
        let decrypter = decoder.userInfo[.decrypterKey] as? ApiDecrypter
        
        if isEncrypted, let decrypter = decrypter {
            // 1. 先把 data 字段解析为原始 Data 或中间加密结构
            // 假设加密数据在 JSON 中是一个加密后的 Data 类型或字符串
            let encryptedData = try container.decode(Data.self, forKey: .data)
            
            // 2. 执行解密
            let decryptedData = try decrypter.decrypt(encryptedData)
            
            // 3. 将解密后的 Data 重新解析为 T
            let subDecoder = JSONDecoder()
            if let decoder = decoder as? JSONDecoder {
                // 拷贝主 decoder 的一些设置 (比如日期格式)
                subDecoder.dateDecodingStrategy = decoder.dateDecodingStrategy
                subDecoder.dataDecodingStrategy = decoder.dataDecodingStrategy
                subDecoder.keyDecodingStrategy = decoder.keyDecodingStrategy
            }
            self.data = try subDecoder.decode(T.self, from: decryptedData)
        } else {
            self.data = try container.decodeIfPresent(T.self, forKey: .data)
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case code
        case message
        case data
        case traceId = "trace_id"
        case isEncrypted = "is_encrypted"
    }
}

public struct ApiResponseDataPlaceholder: Decodable, Sendable {}

// 扩展 CodingUserInfoKey 方便传递解密器
private extension CodingUserInfoKey {
    static let decrypterKey = CodingUserInfoKey(rawValue: "com.objc.api.decrypter")!
}

public struct ApiLogger: Sendable {
    public static func log(request: URLRequest) {
        #if DEBUG
        print("\n🚀 [REQUEST]: \(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")")
        print("💻 cURL:\n\(request.cURLCommand)")
        #endif
    }

    public static func log(responseData: Data?, url: URL?) {
        #if DEBUG
        guard let data = responseData else { return }
        let json = String(data: data, encoding: .utf8) ?? "Non-UTF8 Data"
        print("\n✅ [RESPONSE]: \(url?.absoluteString ?? "")")
        print("📦 Data: \(json)\n")
        #endif
    }
}

extension URLRequest {
    // 生成 cURL 命令
    public var cURLCommand: String {
        guard let url = url else { return "" }
        var components = ["curl -v"]
        components.append("-X \(httpMethod ?? "GET")")
        allHTTPHeaderFields?.forEach { components.append("-H \"\($0): \($1)\"") }
        if let body = httpBody, let bodyString = String(data: body, encoding: .utf8) {
            components.append("-d '\(bodyString)'")
        }
        components.append("\"\(url.absoluteString)\"")
        return components.joined(separator: " \\\n\t")
    }
}
