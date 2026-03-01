//
//  AuthManager.swift
//  CoreKit
//
//  Created by xiaoyuan on 2026/3/1.
//

import Foundation
import Observation

@Observable
// @unchecked告诉编译器：这个类保证线程安全，因为它只在主线程写，拦截器只是读
public final class AuthManager: @unchecked Sendable {
    public private(set) var isLoggedIn: Bool = false
    // 控制登录窗口的弹出
    public var showLoginSheet: Bool = false
    public private(set) var token: String?
    
    public init() {
        
    }
    
    public func requireLogin() {
        if !isLoggedIn {
            showLoginSheet = true
        }
    }
    
    // 登录成功后的状态同步
    @MainActor
    public func updateLoginState(token: String) {
        self.token = token
        self.isLoggedIn = true
        self.showLoginSheet = false
        showLoginSheet = false
    }
    
    @MainActor
    public func logout() {
        self.token = nil
        self.isLoggedIn = false
    }
}
