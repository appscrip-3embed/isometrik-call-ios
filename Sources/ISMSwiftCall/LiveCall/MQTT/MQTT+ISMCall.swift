//
//  MQTT+ISMCall.swift
//  LiveKitCall
//
//  Created by Ajay Thakur on 12/04/24.
//

import Foundation
import CallKit

public protocol CallEventHandlerDelegate: AnyObject {
    func didReceiveMeetingCreated(meeting: ISMMeeting?)
    func didReceiveMeetingEnded(meeting: ISMMeeting?)
    func publishingStarted(meeting: ISMMeeting?)
    func didMemberLeaveTheMeeting(meeting: ISMMeeting?)
    func didReceiveJoinRequestReject(meeting: ISMMeeting?)
    func didReceiveJoinRequestAccept(meeting: ISMMeeting?)
    func didReceiveMessagePublished(meeting: ISMMeeting?, messageBody: String)
}


public struct CallEventHandler {
    
    public static weak var delegate: CallEventHandlerDelegate?
    public  static func handleCallEvents(payload : [UInt8]){
        let meeting : ISMMeeting?
        let data = Data(payload)
        do {
            // Decode Data into your Codable struct
            if let jsonDict = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                print(jsonDict)
            }
            meeting = try JSONDecoder().decode(ISMMeeting.self, from: data)
        } catch {
            meeting = nil
            print("Error decoding data: \(error)")
        }
        
        switch ISMMeetingActions(rawValue: meeting?.action ?? ""){
            
        case .meetingCreated :
            if let meeting ,let senderId =  meeting.createdBy, senderId != ISMConfiguration.getUserId(),!ISMConfiguration.usesPushKit() {
                ISMCallManager.shared.reportIncomingCall(callDetails: meeting)
            }
            ISMCallManager.shared.callDetails = meeting
                delegate?.didReceiveMeetingCreated(meeting: meeting)
        case .meetingEnded, .meetingEndedByHost:
            endCallIfRemoteHangup(meeting: meeting, reason: .remoteEnded)
            delegate?.didReceiveMeetingEnded(meeting: meeting)
        case .memberLeft :
            // Caller hung up before pickup → 1:1 incoming CallKit would otherwise keep ringing.
            endIncomingRingingIfRemoteLeft(meeting: meeting)
            delegate?.didMemberLeaveTheMeeting(meeting: meeting)
       case .joinRequestReject:
            if !endIncomingRingingIfRemoteLeft(meeting: meeting) {
                // joinCall outgoing path has no CallKit UUID in callIDs — still dismiss on remote decline.
                let meetingMatches = ISMCallManager.shared.callDetails?.meetingId == meeting?.meetingId
                    || ISMLiveCallView.shared.meetingId == meeting?.meetingId
                if meetingMatches,
                   ISMCallManager.shared.callDetails?.callType() != .GroupCall,
                   ISMLiveCallView.shared.callStatus != .started {
                    ISMCallManager.shared.cancelHangupTimer()
                    ISMLiveCallView.shared.showNoAnswerView()
                }
            }
            delegate?.didReceiveJoinRequestReject(meeting: meeting)
        case .publishingStarted :
            if let senderId =  meeting?.userId, senderId != ISMConfiguration.getUserId(), meeting?.meetingId == ISMCallManager.shared.callDetails?.meetingId{
                ISMCallManager.shared.cancelHangupTimer()
            }
            delegate?.publishingStarted(meeting: meeting)
        case .joinRequestAccept :
            if let senderId =  meeting?.userId, senderId != ISMConfiguration.getUserId(), ISMCallManager.shared.outgoingCallID != nil{
                ISMCallManager.shared.startTheCall()
            }else if  meeting?.userId ==  ISMConfiguration.getUserId(),let callID = ISMCallManager.shared.callIDs.first, (ISMCallManager.shared.callActiveOnDeviceId == nil)  {
               // Notes : handle the scenario for session on multiple devices. If call is accepted on one device, end on other devices.
                ISMCallManager.shared.endCall(callUUID: callID)
            }
            delegate?.didReceiveJoinRequestAccept(meeting: meeting)
        case .messagePublished :
            if let senderId =  meeting?.senderId, senderId != ISMConfiguration.getUserId(), let messageBody = meeting?.body{
                switch ISMPublishMessageConstants(rawValue: messageBody) {
                case .callRingingMessage:
                    ISMLiveCallView.shared.updateCallStatus(.ringing)
                case .requestToSwitchToVideoCall :
                    if let meeting {
                        ISMLiveCallView.shared.showTheVideoCallRequest(meeting: meeting)
                    }
                case .requestToSwitchToVideoCallRejected:
                    ISMLiveCallView.shared.videoCallRequestDeclined()
                case .requestToSwitchToVideoCallAccepted:
                    ISMLiveCallView.shared.switchToVideoCallrequestAccepted()
                default :
                    break
                }
                delegate?.didReceiveMessagePublished(meeting: meeting, messageBody:messageBody )
            }
          
        default :
            if meeting?.action == "meetingEnded" || meeting?.action == "meetingEndedByHost" {
                endCallIfRemoteHangup(meeting: meeting, reason: .remoteEnded)
                delegate?.didReceiveMeetingEnded(meeting: meeting)
            } else {
                print(meeting?.action ?? "")
            }
        }
        
    }
    
    private static func meetingMatchesCurrentCall(_ meeting: ISMMeeting?) -> Bool {
        guard let meetingId = meeting?.meetingId else { return false }
        return ISMCallManager.shared.callDetails?.meetingId == meetingId
            || ISMLiveCallView.shared.meetingId == meetingId
    }
    
    @discardableResult
    private static func endIncomingRingingIfRemoteLeft(meeting: ISMMeeting?) -> Bool {
        guard meetingMatchesCurrentCall(meeting),
              ISMCallManager.shared.callDetails?.callType() != .GroupCall,
              ISMCallManager.shared.isIncomingCallKitRinging() else {
            return false
        }
        ISMCallManager.shared.reportRemoteCallEnded(reason: .unanswered)
        return true
    }
    
    private static func endCallIfRemoteHangup(meeting: ISMMeeting?, reason: CXCallEndedReason) {
        guard meetingMatchesCurrentCall(meeting) else { return }
        if ISMCallManager.shared.isIncomingCallKitRinging() {
            ISMCallManager.shared.reportRemoteCallEnded(reason: .unanswered)
        } else {
            ISMCallManager.shared.reportRemoteCallEnded(reason: reason)
        }
    }
}
