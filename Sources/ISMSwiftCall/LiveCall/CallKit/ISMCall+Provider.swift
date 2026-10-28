//
//  File.swift
//  
//
//  Created by Ajay Thakur on 03/08/24.
//

import Foundation
import CallKit
import AVFAudio
import UIKit
import LiveKit


class CXISMCallManager: NSObject {
    static let shared = CXISMCallManager()
    
    let provider: CXProvider
    
    override init() {
        self.provider = CXProvider.default
        super.init()
    }
    
}

@available(iOS 14.0, *)
extension CXProvider {
    static var `default`: CXProvider {
        let config = CXProviderConfiguration.default
        return CXProvider(configuration: config)
    }
}



extension ISMCallManager : CXProviderDelegate{
    
    
    //    func provider(_ provider: CXProvider, execute transaction: CXTransaction) -> Bool {
    //
    //    }
    
    
    
    public func providerDidReset(_ provider: CXProvider) {
        // Stop audio
        // End all calls because they are no longer valid
        // Remove all calls from the app's list of calls
        
    }
    
    // What happens when the user accepts the call by pressing the incoming call button? You should implement the method below and call the fulfill method if the call is successful.
    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        
        // Configure audio session
        // Accept call
        // Notify incoming call accepted
        // &&
        
#if !targetEnvironment(simulator)
        // CallKit incoming answer (killed/background or foreground): always run auto mute test path.
        self.shouldRetryMicAfterCallKitAudio = true
        self.startKilledStateAutoMuteWatchdog()
        if UIApplication.shared.applicationState != .active {
            AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
            try? AudioManager.shared.setEngineAvailability(.none)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.finishCallKitHeldAudioIfNeeded()
            }
        } else {
            // App already active when answer fires — still need auto mute; session is ready.
            self.callKitAudioSessionReady = true
            print("[ISMCall] Answer while active — CallKit audio flagged ready for auto mute")
        }
#endif
        
        DispatchQueue.global().async {
            // Request the task assertion and save the ID.
            self.backgroundTaskID = UIApplication.shared.beginBackgroundTask (withName: "Finish Network Tasks") {
                // End the task if time expires.
                UIApplication.shared.endBackgroundTask(self.backgroundTaskID!)
                self.backgroundTaskID = UIBackgroundTaskIdentifier.invalid
            }
            let endBackgroundTaskIfNeeded = {
                if let taskId = self.backgroundTaskID, taskId != .invalid {
                    UIApplication.shared.endBackgroundTask(taskId)
                    self.backgroundTaskID = UIBackgroundTaskIdentifier.invalid
                }
            }
            if let id = self.callDetails?.meetingId{
                self.callConnectedTime = Date()
                self.cancelHangupTimer()
                self.callActiveOnDeviceId = ISMDeviceId
                let hasUserToken = !ISMConfiguration.getUserToken().isEmpty
                print("[ISMCall] Answer → POST /meetings/v1/accept meetingId=\(id) hasUserToken=\(hasUserToken) appState=\(UIApplication.shared.applicationState.rawValue)")
                self.viewModel.accpetCall(meetingId: id) { response in
                    guard let rtcToken = response.rtcToken else{
                        print("[ISMCall] Accept succeeded but rtcToken missing — ending CallKit call")
                        self.endCall(callUUID:self.callIDs.first ?? UUID())
                        endBackgroundTaskIfNeeded()
                        return
                    }
                    print("[ISMCall] Accept OK meetingId=\(id) rtcTokenLength=\(rtcToken.count) — joining LiveKit (server should emit joinRequestAccept)")
                    self.pushLiveCallView(rtcToken: rtcToken, meetingID: id, callType: self.callDetails?.callType() ?? .AudioCall)
                    endBackgroundTaskIfNeeded()
                }failure: {
                    // Meeting already ended, or the stored credentials are stale. Without this the
                    // CallKit call stays "connected" with no room joined and no audio either way.
                    print("[ISMCall] Accept FAILED meetingId=\(id) hasUserToken=\(!ISMConfiguration.getUserToken().isEmpty) — ending CallKit call")
                    self.endCall(callUUID:self.callIDs.first ?? UUID())
                    endBackgroundTaskIfNeeded()
                }
            } else {
                print("[ISMCall] Answer ignored — callDetails.meetingId is nil")
                endBackgroundTaskIfNeeded()
            }
        }
        
        action.fulfill()
        
        if action.callUUID == ISMCallManager.shared.callIDs.first ?? UUID() && action.isComplete {
            // The call with UUID myCallUUID has been successfully answered
            let answerCallAction = CXAnswerCallAction(call: ISMCallManager.shared.callIDs.first ?? UUID())
            let transaction = CXTransaction(action: answerCallAction)
            
            callController.request(transaction) { error in
                if let error = error {
                    print("Error answering call: \(error.localizedDescription)")
                } else {
                    print("Call answered successfully")
                    
                }
            }
        }
        
        return
    }
    
    // What happens when the user taps the reject button? Call the fail method if the call is unsuccessful. It checks the call based on the UUID. It uses the network to connect to the end call method you provide.
    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        
        
#if !targetEnvironment(simulator)
        guard !callObserver.calls.isEmpty else {
            return
        }
        
        if action.callUUID == ISMCallManager.shared.callIDs.first ?? UUID() {
            let endCallAction = CXEndCallAction(call: action.callUUID)
            let transaction = CXTransaction(action: endCallAction)
            
            callController.request(transaction) { error in
                if let error = error {
                    print("CXEndCallAction Error ending call: \(error.localizedDescription)")
                    provider.reportCall(with: action.callUUID, endedAt: Date(), reason: .remoteEnded)
                    return
                } else {
                    print("CXEndCallAction ended successfully")
                }
                DispatchQueue.main.async {
                    ISMLiveCallView.shared.disconnectCall()
                }
                
            }
        }
        
        DispatchQueue.global().async {
            // Request the task assertion and save the ID.
            self.backgroundTaskID = UIApplication.shared.beginBackgroundTask (withName: "Finish Network Tasks") {
                // End the task if time expires.
                UIApplication.shared.endBackgroundTask(self.backgroundTaskID!)
                self.backgroundTaskID = UIBackgroundTaskIdentifier.invalid
            }
            if self.callActiveOnDeviceId != nil {
                if self.callObserver.calls.contains(where: { $0.hasConnected || $0.isOutgoing }) {
                    // The call was picked up and then ended
                    print("Call was picked up and ended")
                    self.leaveCall()
                } else {
                    // The call was not connected (e.g., declined before connecting)
                    print("Call was declined or ended before connecting")
                    self.rejectCall()
                }
            }else{
                self.rejectCall()
            }
            
            // End the task assertion.
            UIApplication.shared.endBackgroundTask(self.backgroundTaskID!)
            self.backgroundTaskID = UIBackgroundTaskIdentifier.invalid
        }
        
        action.fulfill()
        return
#endif
#if targetEnvironment(simulator)
        //        self.leaveCall()
#endif
    }
    
    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        // Get call object
        // Configure audio session
        // Add call to ISMCallManager.callIDs
        // Report connection started
        
        // Perform necessary actions for starting an outgoing call
        let handle = action.handle
        // Use the handle to start the call
        ISMCallManager.shared.addCall(uuid: action.callUUID)
        
        // Assume the call is connected after a delay for demonstration purposes
        action.fulfill()
        
    }
    
    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // CallKit has activated the session — LiveKit can now start (and configure) audio.
        if shouldRetryMicAfterCallKitAudio {
            finishCallKitHeldAudioIfNeeded(audioSession: audioSession)
            return
        }
        do {
            try AudioManager.shared.setEngineAvailability(.default)
        } catch {
            print("Failed to release audio engine on didActivate: \(error.localizedDescription)")
        }
    }
    
    /// Killed/background CallKit path only. Configure session CallKit activated, release engine, recover once.
    func finishCallKitHeldAudioIfNeeded(audioSession: AVAudioSession = .sharedInstance()) {
        guard shouldRetryMicAfterCallKitAudio else { return }
        do {
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
            try AudioManager.shared.setEngineAvailability(.default)
            callKitAudioSessionReady = true
            print("[ISMCall] CallKit audio session ready")
        } catch {
            print("[ISMCall] Failed to release held audio engine: \(error.localizedDescription)")
        }
        scheduleCallKitAudioRecoveryIfNeeded()
    }
    
    func markLiveKitRoomConnected() {
        liveKitRoomConnected = true
        if shouldRetryMicAfterCallKitAudio && !callKitAudioSessionReady {
            callKitAudioSessionReady = true
            print("[ISMCall] Room connected — audio session marked ready")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.triggerKilledStateAutoMutePulse()
        }
    }
    
    func scheduleCallKitAudioRecoveryIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.triggerKilledStateAutoMutePulse()
        }
    }
    
    /// Restore LiveKit automatic session handling after a killed-state CallKit answer.
    func restoreAutomaticAudioSessionIfNeeded() {
        visibleAutoMutePulseStarted = false
        restoreLiveKitAudioAfterCallKitHandoff()
    }
    
    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // Called when the provider's audio session is deactivated
    }
    
    public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        // Called when an action times out
        print("**Called when an action times out **")
    }
    
    func provider(_ provider: CXProvider, didUpdate call: CXCall) {
        // Called when the call's state changes
        switch call.hasEnded {
        case true:
            print("Call ended")
        case false:
            if call.isOutgoing && call.hasConnected {
                print("Outgoing call connected")
            } else if call.isOutgoing && call.hasEnded {
                print("Outgoing call failed")
            }
        }
    }
    
    
    
    
    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        // Update holding state
        // Mute the call when it's on hold
        // Stop the video when it's a video call
        
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        if !callIDs.isEmpty {
            ISMLiveCallView.shared.isMute = action.isMuted
            ISMLiveCallView.shared.updateMuteStatus()
        }
        
        action.fulfill()
    }
    
    
    func fetchMembers(meetingId : String, completion :@escaping ([ISMCallMember])->()){
        
        self.viewModel.fetchMembersInMeeting(meetingId:meetingId) { members in
            
          completion(members)
        }
    }
    
    
    func joinCall(meetingId : String){
        
        guard  ISMLiveCallView.shared.meetingId == nil else {
            
            print("You can join other call when on a call.")
            return
        }
        
        self.viewModel.startPublishing(meetingId: meetingId) { rtc in
            
            guard let rtcToken = rtc.rtcToken else{
                return
            }
            ISMCallManager.shared.callDetails = ISMMeeting(meetingId: meetingId, customType: ISMLiveCallType.AudioCall.rawValue, audioOnly: true)
            // Same no-answer timeout as createCall — joinCall has no CallKit outgoing UUID.
            ISMCallManager.shared.scheduleCallHangup()
            ISMCallManager.shared.pushLiveCallView(rtcToken: rtcToken, meetingID: meetingId, callType: .AudioCall, isInitiator: true)
        }
    }
    
    
    func createCall(members : [ISMCallMember], conversationId : String? = nil, callType : ISMLiveCallType, meetingDescription : String? = nil){
        guard canMakeAOutgoingCall() else{
            print("There is an active call")
            return
        }
        
        let memberIds = members.compactMap{ $0.memberId }
        guard !memberIds.isEmpty else{
            return
        }
        let type : ISMLiveCallType = members.count > 1 ? .GroupCall  : callType
        self.viewModel.createMeeting(memberIds:memberIds,conversationId:conversationId,callType: type, meetingDescription: meetingDescription) { callDetails in
            
            guard let rtcToken = callDetails.rtcToken, let meetingId = callDetails.meetingId else{
                return
            }
            self.callConnectedTime = nil
            ISMCallManager.shared.members = members
            
#if !targetEnvironment(simulator)
            // Code to be excluded on the simulator
            if type == .GroupCall {
                self.reportOutgoingCall(handleName: meetingDescription ?? "Group Call" ,token: rtcToken,meetingId: meetingId, videoEnabled: true)
            }else if members.count == 1 , let callUser = members.first {
                self.reportOutgoingCall(handleName: callUser.memberName ?? callUser.memberIdentifier ?? "",token: rtcToken,meetingId: meetingId, videoEnabled: type == .VideoCall)
             
            }
#endif
            
            ISMCallManager.shared.callDetails = callDetails
            ISMCallManager.shared.callDetails?.meetingDescription = meetingDescription
            ISMCallManager.shared.pushLiveCallView(rtcToken: rtcToken, meetingID: meetingId, callType: type,isInitiator: true)
        }
    }
    
    
    
    func publishMessage(message : ISMPublishMessageConstants){
        guard let meetingId = callDetails?.meetingId else{
            return
        }
        self.viewModel.publishMessage(meetingId: meetingId, message: message.rawValue){
            print(" Message sent Successfully")
        }
    }
    
    func leaveCall(){
        self.cancelHangupTimer()
        self.restoreAutomaticAudioSessionIfNeeded()
        guard  let meetingId = callDetails?.meetingId else{
            return
        }
        self.viewModel.leaveMeeting(meetingId:meetingId){
            self.callActiveOnDeviceId = nil
            self.callConnectedTime = nil
            self.callDetails = nil
            self.members = nil
            self.outgoingCallID = nil
            self.removeAllCalls()
            print("Left Meeting Successfully")
            
        }
    }
    
    func rejectCall(){
        self.cancelHangupTimer()
        self.restoreAutomaticAudioSessionIfNeeded()
        guard !callIDs.isEmpty, let meetingId = callDetails?.meetingId else{
            return
        }
        self.viewModel.rejectCall(meetingId:meetingId){_ in
            self.callActiveOnDeviceId = nil
            self.callConnectedTime = nil
            self.callDetails = nil
            self.members = nil
            self.outgoingCallID = nil
            self.removeAllCalls()
            print("Rejected Successfully")
            
        }
    }
    
    func pushLiveCallView(rtcToken: String , meetingID : String, callType: ISMLiveCallType, isInitiator : Bool = false, windowRetry: Int = 0 ){
        DispatchQueue.main.async {
            let windows = UIApplication.shared.connectedScenes
                .compactMap({$0 as? UIWindowScene})
                .flatMap({$0.windows})
            // Launched by a VoIP push there is no key window yet, and without a window the call
            // view is never added — so the LiveKit room is never joined and the call is silent.
            guard let window = windows.first(where: {$0.isKeyWindow}) ?? windows.first else{
                guard windowRetry < 20 else {
                    print("[ISMCall] pushLiveCallView — no window after retries, room not joined")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.pushLiveCallView(rtcToken: rtcToken, meetingID: meetingID, callType: callType, isInitiator: isInitiator, windowRetry: windowRetry + 1)
                }
                return
            }
            let panGesture = UIPanGestureRecognizer(target: self, action: #selector(self.panGestureHandlerForDraggableView))
            panGesture.isEnabled = false
            let liveKit = ISMLiveCallView.shared
            liveKit.configure(frame:window.bounds , rtcToken: rtcToken,meetingId:meetingID,callType: callType, isInitiator: isInitiator)
            liveKit.panGesture = panGesture
            liveKit.addGestureRecognizer(panGesture)
            window.addSubview(liveKit)
            if self.shouldRetryMicAfterCallKitAudio {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    self?.triggerKilledStateAutoMutePulse()
                }
            }
        }
    }
    
    @objc func panGestureHandlerForDraggableView(gesture: UIPanGestureRecognizer){
        
        guard let window = UIApplication.shared.connectedScenes
            .filter({$0.activationState == .foregroundActive})
            .compactMap({$0 as? UIWindowScene})
            .first?.windows
            .filter({$0.isKeyWindow}).first else{
            return
        }
        let location = gesture.location(in: window)
        let draggedView = gesture.view!
        draggedView.center = location
        
        if gesture.state == .ended {
            if draggedView.frame.midX >= window.layer.frame.width / 2 {
                UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 1, options: .curveEaseIn, animations: {
                    
                    if draggedView.frame.midY >= window.layer.frame.height / 2{
                        draggedView.frame.origin.x = window.frame.width - 160
                        draggedView.frame.origin.y = window.frame.height - (190 + window.safeAreaInsets.bottom)
                    }else{
                        
                        draggedView.frame.origin.x = window.frame.width - 160
                        draggedView.frame.origin.y = window.safeAreaInsets.top + 10
                    }
                    
                }, completion: nil)
            }else{
                UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 1, options: .curveEaseIn, animations: {
                    if draggedView.frame.midY >= window.layer.frame.height / 2{
                        draggedView.frame.origin.x = 10
                        draggedView.frame.origin.y = window.frame.height - (160 + window.safeAreaInsets.bottom)
                    }else{
                        
                        draggedView.frame.origin.x = 10
                        draggedView.frame.origin.y = window.safeAreaInsets.top + 10
                    }
                }, completion: nil)
            }
        }
    }
    
    
    func updateMuteStatus(isMute: Bool, completion: ((Bool) -> Void)? = nil) {
        let request = { [weak self] in
            guard let self else {
                completion?(false)
                return
            }
            guard let callId = self.callIDs.first else {
                completion?(false)
                return
            }
            let muteCallAction = CXSetMutedCallAction(call: callId, muted: isMute)
            let transaction = CXTransaction(action: muteCallAction)
            self.callController.request(transaction) { error in
                if let error = error {
                    print("[ISMCall] CallKit mute(\(isMute)) failed: \(error.localizedDescription)")
                }
                completion?(error == nil)
            }
        }
        if Thread.isMainThread {
            request()
        } else {
            DispatchQueue.main.async(execute: request)
        }
    }
    
    @objc func handleAudioRouteChange(notification: Notification) {
        guard !isAutoMutePulseActive else { return }
        // Handle audio route change here
        
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        print("****REASON \(reason)")
        print("****REASON VAlue \(reasonValue)")
        switch reason {
            
        case .categoryChange, .override:
            // Speaker has changed, handle accordingly
            // Debounce the action to ignore if it occurs again within 2 second
            
            let debouncer = Debouncer(delay: 2.0)
            
            debouncer.debounce {
                // Speaker has changed, handle accordingly
                if let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription,
                   let outputs = previousRoute.outputs.first {
                    print("****\(outputs)")
                    
                    if outputs.portType == .builtInSpeaker, ISMLiveCallView.shared.isSpeakerOn {
                        self.switchToReceiver()
                    } else if outputs.portType == .builtInReceiver, !ISMLiveCallView.shared.isSpeakerOn {
                        self.switchToSpeaker()
                    }
                }
            }
            
        default:
            break
        }
    }
    
    
    
    func switchToSpeaker() {
        
        guard !ISMLiveCallView.shared.isSpeakerOn else {
            return
        }
        ISMLiveCallView.shared.isSpeakerOn = true
        ISMLiveCallView.shared.updateSpeakerStatus()
    }
    
    func switchToReceiver() {
        guard ISMLiveCallView.shared.isSpeakerOn else {
            return
        }
        ISMLiveCallView.shared.isSpeakerOn = false
        ISMLiveCallView.shared.updateSpeakerStatus()
    }
    
    
}

extension CXProviderConfiguration {
    // The app's provider configuration, representing its CallKit capabilities
    @available(iOS 14.0, *)
    static var `default`: CXProviderConfiguration {
        let providerConfiguration = CXProviderConfiguration()
        providerConfiguration.iconTemplateImageData = UIImage(systemName: "globe").flatMap { $0.pngData() }
        providerConfiguration.supportsVideo = true
        providerConfiguration.maximumCallsPerCallGroup = 1
        providerConfiguration.maximumCallGroups = 1
        providerConfiguration.supportedHandleTypes = [.generic]
        providerConfiguration.includesCallsInRecents = true
        providerConfiguration.ringtoneSound = "Ringing.mp3"
        
        return providerConfiguration
    }
}
