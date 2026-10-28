//
//  ISMISMCallManager.swift
//  ISMLiveCall
//
//  Created by Rahul Sharma on 28/02/24.
//

import Foundation
import CallKit
import UIKit
import AVFAudio
import PushKit
import LiveKit


public class ISMCallManager: NSObject {
    
    /// Singleton instance
    public static let shared = ISMCallManager()
    
    // Call management properties
    private var callHangupTimer: ISMCallHangupTimer?
    private(set) var callIDs: [UUID] = []
    var backgroundTaskID: UIBackgroundTaskIdentifier?
    var callDetails: ISMMeeting?
    public var members: [ISMCallMember]?
    var outgoingCallID: UUID?
    public var callConnectedTime: Date?
    var callActiveOnDeviceId: String?
    /// Set only when answering from background/killed (CallKit manual audio). Cleared on call end.
    var shouldRetryMicAfterCallKitAudio = false
    /// True after `didActivate` releases the held LiveKit engine (killed-state path only).
    var callKitAudioSessionReady = false
    /// True after LiveKit room reaches `.connected` (killed-state path only).
    var liveKitRoomConnected = false
    /// True once mute→unmute recovery succeeds (killed-state path only).
    var callKitAudioRecoveryCompleted = false
    /// Ensures killed-state auto mute→unmute runs only once per call.
    var visibleAutoMutePulseStarted = false
    /// While auto mute→unmute runs, suppress ringer / output flicker (manual mute unchanged).
    var isAutoMutePulseActive = false
    
    /// Manual mute: block any pending auto pulse.
    func cancelCallKitAudioRecovery() {
        callKitAudioRecoveryCompleted = true
        visibleAutoMutePulseStarted = true
    }
    
    /// Re-enable LiveKit session management after CallKit handoff (killed-state path).
    func restoreLiveKitAudioAfterCallKitHandoff() {
        guard shouldRetryMicAfterCallKitAudio else { return }
        shouldRetryMicAfterCallKitAudio = false
        callKitAudioSessionReady = false
        liveKitRoomConnected = false
        callKitAudioRecoveryCompleted = false
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = true
        try? AudioManager.shared.setEngineAvailability(.default)
        print("[ISMCall] LiveKit audio handoff complete")
    }
    
    /// Killed-state: auto mute→unmute (visible, same steps as manual Mute button).
    func performKilledStateAutoMutePulse() {
        guard !visibleAutoMutePulseStarted else { return }
        guard callIDs.first != nil else { return }
        guard ISMLiveCallView.shared.meetingId != nil else { return }
        
        visibleAutoMutePulseStarted = true
        isAutoMutePulseActive = true
        let view = ISMLiveCallView.shared
        let wasKilled = shouldRetryMicAfterCallKitAudio
        view.stopAudio()
        setRemoteCallAudioMuted(true)
        
        print("[ISMCall] Auto mute pulse — mute")
        view.isMute = true
        view.updateMuteStatus()
        updateMuteStatus(isMute: true) { [weak self] _ in
            guard let self else { return }
            if wasKilled {
                self.restoreLiveKitAudioAfterCallKitHandoff()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                print("[ISMCall] Auto mute pulse — unmute")
                view.isMute = false
                view.updateMuteStatus()
                self.updateMuteStatus(isMute: false) { _ in
                    self.callKitAudioRecoveryCompleted = true
                    self.setRemoteCallAudioMuted(false)
                    self.isAutoMutePulseActive = false
                    print("[ISMCall] Auto mute pulse complete")
                }
            }
        }
    }
    
    /// Mute remote playback briefly during auto mute pulse so mic/session toggles are inaudible.
    private func setRemoteCallAudioMuted(_ muted: Bool) {
        let view = ISMLiveCallView.shared
        Task {
            for participant in view.room.remoteParticipants.values {
                for publication in participant.audioTracks {
                    (publication.track as? RemoteAudioTrack)?.volume = muted ? 0 : 1.0
                }
            }
        }
    }
    
    func triggerKilledStateAutoMutePulse() {
        guard shouldRetryMicAfterCallKitAudio else { return }
        guard !visibleAutoMutePulseStarted else { return }
        DispatchQueue.main.async { [weak self] in
            self?.performKilledStateAutoMutePulse()
        }
    }
    
    /// ponytail: retry auto mute every 1s for 30s until it runs (killed-state answer)
    func startKilledStateAutoMuteWatchdog() {
        guard shouldRetryMicAfterCallKitAudio else { return }
        for tick in 1...30 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(tick)) { [weak self] in
                guard let self, self.shouldRetryMicAfterCallKitAudio, !self.visibleAutoMutePulseStarted else { return }
                self.triggerKilledStateAutoMutePulse()
            }
        }
    }
    
    // CallKit properties
    let callController = CXCallController()
    let callObserver = CXCallObserver()
    let audioSession = AVAudioSession.sharedInstance()
    let provider = CXISMCallManager.shared.provider
    
    // View model
    let viewModel = ISMCallMeetingViewModel()
    
    // MARK: - Initializers
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioRouteChange(notification:)), name: AVAudioSession.routeChangeNotification, object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
    }

    
    // MARK: Call Management
    func containsCall(uuid: UUID) -> Bool {
        return ISMCallManager.shared.callIDs.contains(where: { $0 == uuid })
    }
    
    func addCall(uuid: UUID) {
        self.callIDs.append(uuid)
    }
    
    func removeCall(uuid: UUID) {
        self.callIDs.removeAll { $0 == uuid }
    }
    
    func removeAllCalls() {
        self.callIDs.removeAll()
    }
    
    
    func endCall(callUUID: UUID) {
        let endCallAction = CXEndCallAction(call: callUUID)
        let transaction = CXTransaction(action: endCallAction)
        
        callController.request(transaction) { error in
            if let error = error {
                print("Error ending call: \(error.localizedDescription)")
                self.provider.reportCall(with: callUUID, endedAt: Date(), reason: .remoteEnded)
                DispatchQueue.main.async {
                    ISMLiveCallView.shared.disconnectCall()
                }
            } else {
                print("Call ended successfully")
                
            }
        }
    }
    
    /// Posted when an incoming CallKit ring ends unanswered (caller hung up before answer).
    public static let incomingCallMissedNotification = Notification.Name("ISMIncomingCallMissed")
    
    /// Notify the host app so it can show "Missed call from {name}".
    public static func postIncomingCallMissed(
        callerName: String?,
        conversationId: String? = nil,
        meetingId: String? = nil
    ) {
        var userInfo: [String: String] = [:]
        if let name = callerName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            userInfo["callerName"] = name
        }
        if let conversationId = conversationId?.trimmingCharacters(in: .whitespacesAndNewlines), !conversationId.isEmpty {
            userInfo["conversationId"] = conversationId
        }
        if let meetingId = meetingId?.trimmingCharacters(in: .whitespacesAndNewlines), !meetingId.isEmpty {
            userInfo["meetingId"] = meetingId
        }
        NotificationCenter.default.post(
            name: incomingCallMissedNotification,
            object: nil,
            userInfo: userInfo
        )
    }
    
    /// Caller hung up before we answered — stop CallKit ringing as a missed call.
    /// Uses `reportCall` so we don't send a local CXEndCallAction (that path calls reject).
    func reportRemoteCallEnded(reason: CXCallEndedReason) {
        let endOnMain = { [weak self] in
            guard let self else { return }
            let myId = ISMConfiguration.getUserId()
            let wasIncomingUnanswered = reason == .unanswered
                && self.outgoingCallID == nil
                && self.callConnectedTime == nil
                && (!self.callIDs.isEmpty || self.callDetails != nil)
            let callerName = self.callDetails?.initiatorName
                ?? self.members?.first(where: { ($0.memberId ?? "") != myId })?.memberName
            let conversationId = self.callDetails?.conversationId
            let meetingId = self.callDetails?.meetingId
            
            self.cancelHangupTimer()
            self.restoreAutomaticAudioSessionIfNeeded()
            if let callID = self.callIDs.first {
                self.provider.reportCall(with: callID, endedAt: Date(), reason: reason)
            }
            ISMLiveCallView.shared.disconnectCall()
            self.callActiveOnDeviceId = nil
            self.callConnectedTime = nil
            self.callDetails = nil
            self.members = nil
            self.outgoingCallID = nil
            self.removeAllCalls()
            
            if wasIncomingUnanswered {
                Self.postIncomingCallMissed(
                    callerName: callerName,
                    conversationId: conversationId,
                    meetingId: meetingId
                )
            }
        }
        if Thread.isMainThread {
            endOnMain()
        } else {
            DispatchQueue.main.async(execute: endOnMain)
        }
    }
    
    func isRemoteHangupAction(_ action: String?) -> Bool {
        switch action {
        case "meetingEndedDueToNoUserPublishing",
             "meetingEnded",
             "meetingEndedByHost",
             "memberLeave",
             "joinRequestReject":
            return true
        default:
            return false
        }
    }
    
    func isIncomingCallKitRinging() -> Bool {
        outgoingCallID == nil
            && !callIDs.isEmpty
            && ISMLiveCallView.shared.callStatus != .started
    }
    
    
    func canMakeAOutgoingCall() -> Bool{
        
        if callObserver.calls.contains(where: { $0.hasConnected || $0.isOutgoing }) {
            // There is an active call, handle accordingly
            //            if let topController =  ISMLiveKitCallUtil.topPresentedController(){
            //                topController.showISMCallErrorAlerts(message:"You can not place a call if you're already on another call.")
            //            }
            return false
        } else {
            // There is no active call, proceed with making the outgoing call
            return true
        }
        
    }
    
    func reportOutgoingCall(handleName: String,token:String, meetingId : String,videoEnabled : Bool) {
        
        let handle = CXHandle(type: .generic, value: handleName)
        
        provider.setDelegate(self, queue: nil)
        let newCall = UUID()
        
        outgoingCallID = newCall
        // Report outgoing call
        provider.reportOutgoingCall(with: newCall, startedConnectingAt: Date())
        // Start the call action
        let startCallAction = CXStartCallAction(call: newCall, handle: handle)
        startCallAction.isVideo = videoEnabled
        startCallAction.contactIdentifier = handleName
        let transaction = CXTransaction(action: startCallAction)
        
        callController.request(transaction) { error in
            if let error = error {
                print("Error starting call: \(error.localizedDescription)")
            } else {
                print("Call started successfully")
                self.callActiveOnDeviceId = ISMDeviceId
                self.scheduleCallHangup()
            }
        }
    }
    
    // Start the call outgoing call if it is accepted on other end
    func startTheCall(){
        
        guard let outgoingCallID else{
            return
        }
        // add -2 to assume call is connected early to sync the time on incoming side.
        
        callConnectedTime = Date().addingTimeInterval(-2)
        self.cancelHangupTimer()
        self.provider.reportOutgoingCall(with:outgoingCallID , connectedAt: callConnectedTime)
        self.outgoingCallID = nil // clear the outgoingCallId to avoid the hangup case of no answer
       
       
    }
    
    
    /// To report a call without the Pushkit.
    func reportIncomingCall(callDetails : ISMMeeting){
        // 1: Create an incoming call update object. This object stores different types of information about the caller. You can use it in setting whether the call has a video.
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callDetails.initiatorName ?? "")
        
        // 2: Create and set configurations about how the calling application should behave
        if #available(iOS 14.0, *) {
            update.hasVideo = callDetails.callType() == .VideoCall
            provider.setDelegate(self, queue: nil)
            let newCall =  UUID()
            provider.reportNewIncomingCall(with:newCall, update: update, completion: { error in
                if error == nil{
                    ISMCallManager.shared.callDetails = callDetails
                    ISMCallManager.shared.publishMessage(message: .callRingingMessage)
                    ISMCallManager.shared.addCall(uuid: newCall)
                    ISMCallManager.shared.members = callDetails.members
                    
                }
            })
            
        }
        else {
            // Fallback on earlier versions
        }
    }
    
    /// hangup if  call is not connected within timeInterval seconds
    func scheduleCallHangup() {
#if !targetEnvironment(simulator)
        callHangupTimer?.cancel()
        callHangupTimer = ISMCallHangupTimer(timeInterval: 60.0, hangupHandler: hangupCall)
        callHangupTimer?.start()
#endif
    }
    
    func cancelHangupTimer() {
        callHangupTimer?.cancel()
    }
    
    func hangupCall() {
        print("Call is being hung up due to no answer.")
        //Outgoing call (CallKit startCall path)
        if let _ = self.outgoingCallID, self.callDetails?.meetingId == ISMLiveCallView.shared.meetingId {
            ISMLiveCallView.shared.showNoAnswerView()
        }//Incoming call
        else if let callUUID = self.callIDs.first {
            self.endCall(callUUID:callUUID)
            self.rejectCall()
        }
        // joinCall outgoing path — no CallKit UUID; still end the ringing UI.
        else if ISMLiveCallView.shared.meetingId != nil,
                ISMLiveCallView.shared.callStatus != .started {
            ISMLiveCallView.shared.showNoAnswerView()
        }
    }
    
    func joinCall(callDetails : ISMMeeting?){
        if let id = self.callDetails?.meetingId{
            self.callConnectedTime = Date()
            self.cancelHangupTimer()
            self.callActiveOnDeviceId = ISMDeviceId
            self.viewModel.accpetCall(meetingId: id) { response in
                guard let rtcToken = response.rtcToken else{
                    self.endCall(callUUID:self.callIDs.first ?? UUID())
                    return
                }
                self.pushLiveCallView(rtcToken: rtcToken, meetingID: id, callType: self.callDetails?.callType() ?? .AudioCall)
            }failure: {
                // If meeting is already Ended
                //  self.endCall(callUUID:self.callIDs.first ?? UUID())
            }
        }
    }
}



class CallObserverDelegate: NSObject, CXCallObserverDelegate {
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        if !call.hasConnected {
            print("Call changed before answering")
        } else {
            print("Call changed after answering")
        }
    }
}
