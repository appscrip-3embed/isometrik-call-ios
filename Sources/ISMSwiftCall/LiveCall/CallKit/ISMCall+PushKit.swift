//
//  File.swift
//  
//
//  Created by Ajay Thakur on 03/08/24.
//

import Foundation
import PushKit
import CallKit
import AVFAudio

// PushRegistry methods
public extension ISMCallManager{
    
    
    
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else {
            return
        }
        
        let token = pushCredentials.token.map { String(format: "%02.2hhx", $0) }.joined()
        ISMPushKitToken.shared.newToken = token
        self.updatePushRegisteryToken()
    }
    
    func updatePushRegisteryToken(){
        if !ISMConfiguration.getUserToken().isEmpty ,let token =  ISMPushKitToken.shared.newToken,   ISMPushKitToken.shared.needToUpdate(){
            viewModel.updatePushRegisteryApnsToken(addApnsDeviceToken: true, apnsDeviceToken: token) {
                ISMPushKitToken.shared.updatedOnServer()
            }
        }
    }
    
    
    
    
    
    func pushRegistry(_ registry: PKPushRegistry,
                      didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType,
                      completion: (() -> Void)?){
        
        guard type == .voIP else {
            return
        }
        
        
        do {
            let data = try JSONSerialization.data(withJSONObject: payload.dictionaryPayload, options: [])
            
            let pushPayload = try JSONDecoder().decode(ISMMeeting.self, from: data)
            
            let callDetails = pushPayload
            
            // Caller already hung up — stop any ringing CallKit call as missed.
            if isRemoteHangupAction(callDetails.action) {
                if callDetails.meetingId != nil,
                   callDetails.meetingId == ISMCallManager.shared.callDetails?.meetingId,
                   !ISMCallManager.shared.callIDs.isEmpty {
                    reportRemoteCallEnded(reason: .unanswered)
                    completion?()
                    return
                }
                let update = CXCallUpdate()
                update.remoteHandle = CXHandle(type: .generic, value: callDetails.initiatorName ?? "")
                provider.setDelegate(self, queue: nil)
                let uuid = UUID()
                provider.reportNewIncomingCall(with: uuid, update: update) { _ in
                    self.provider.reportCall(with: uuid, endedAt: Date(), reason: .unanswered)
                    ISMCallManager.postIncomingCallMissed(
                        callerName: callDetails.initiatorName,
                        conversationId: callDetails.conversationId,
                        meetingId: callDetails.meetingId
                    )
                    completion?()
                }
                return
            }
            
            // Duplicate incoming VoIP for the same ringing meeting — don't start a second ring.
            if callDetails.meetingId != nil,
               callDetails.meetingId == ISMCallManager.shared.callDetails?.meetingId,
               !ISMCallManager.shared.callIDs.isEmpty {
                completion?()
                return
            }
            
            let handleName = callDetails.callType() == .GroupCall ? callDetails.meetingDescription ?? "Group Call" : callDetails.initiatorName ?? ""
            
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: handleName)
            
            // 2: Create and set configurations about how the calling application should behave
            
            if #available(iOS 14.0, *) {
                update.hasVideo = callDetails.callType() == .VideoCall
                provider.setDelegate(self, queue: nil)
                let newCall =  UUID()
                provider.reportNewIncomingCall(with:newCall, update: update, completion: { error in
                    if error == nil{
                        
                        if !ISMMQTTManager.shared.hasConnected{
                            ISMMQTTManager.shared.connect(clientId: ISMConfiguration.getUserId())
                        }
                        ISMCallManager.shared.callDetails = callDetails
                      
                        ISMCallManager.shared.addCall(uuid: newCall)
                        
                        ISMCallManager.shared.members = callDetails.members
                        
                        self.scheduleCallHangup()
                        
                        if callDetails.callType() != .GroupCall{
                            ISMCallManager.shared.publishMessage(message: .callRingingMessage)
                        }
                        
                        completion?()
                    }
                })
                
            }
            
        } catch {
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: "Unknown")
            
            provider.reportNewIncomingCall(with:UUID(), update: update) { error in
                print("Error decoding push payload: \(String(describing: error))")
                completion?()
            }
            
        }
        
    }
    
    func invalidatePushKitAPNSDeviceToken(_ registry: PKPushRegistry? = nil, type: PKPushType){
        guard type == .voIP else { return }
        let token = ISMPushKitToken.shared.token ?? ISMPushKitToken.shared.newToken
        guard let token, !token.isEmpty else { return }
        unregisterVoIPDeviceToken(token)
    }
    
    /// Remove VoIP APNs token from Isometrik so calls stop after logout.
    public func unregisterVoIPDeviceToken(_ token: String, completion: (() -> Void)? = nil) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion?()
            return
        }
        guard !ISMConfiguration.getUserToken().isEmpty else {
            ISMPushKitToken.shared.clear()
            ISMPushKitToken.shared.newToken = nil
            completion?()
            return
        }
        viewModel.updatePushRegisteryApnsToken(addApnsDeviceToken: false, apnsDeviceToken: trimmed) {
            ISMPushKitToken.shared.clear()
            ISMPushKitToken.shared.newToken = nil
            completion?()
        }
    }
    
    /// Apple requires reporting every VoIP push to CallKit — end immediately when logged out.
    public func endIncomingPushWithoutRinging(completion: (() -> Void)? = nil) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: " ")
        provider.setDelegate(self, queue: nil)
        let uuid = UUID()
        provider.reportNewIncomingCall(with: uuid, update: update) { _ in
            self.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
            completion?()
        }
    }
}
