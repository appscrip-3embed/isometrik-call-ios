//
//  File.swift
//  
//
//  Created by Ajay Thakur on 10/07/24.
//

import Foundation
import UIKit

class ISMAudioCallCollectionViewCell: UICollectionViewCell {
    
    let profileView = ProfileView()
    
    var startTime : Date?
    var timer: Timer?
    var seconds: Int = 0
    
    // MARK: - Init
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        timer?.invalidate()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        timer?.invalidate()
        timer = nil
        startTime = nil
        profileView.timerLabel.text = nil
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        // Adjust the views inside the cell
        self.profileView.topSpaceView.isHidden = self.bounds.size.height < 200
        // Keep status/timer visible under the name on the full-screen audio call.
        self.profileView.timerLabel.isHidden = false
    }
    
    // MARK: - Setup
    private func setupViews() {
        profileView.frame = bounds
        profileView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.addSubview(profileView)
    }
    
    // MARK: - Public Methods
    func configure(member: ISMCallMember?,status: ISMCallStatus?) {
        profileView.nameLabel.text = member?.memberName
        profileView.nameLabel.isHidden = false
        profileView.timerLabel.isHidden = false

        if status == .reconnecting {
            timer?.invalidate()
            timer = nil
            profileView.timerLabel.text = "Reconnecting..."
        } else if status == .started {
            timer?.invalidate()
            if ISMCallManager.shared.callConnectedTime == nil {
                ISMCallManager.shared.callConnectedTime = Date()
            }
            if let time = ISMCallManager.shared.callConnectedTime {
                self.startTime = time
                startTimer()
                updateAppTimer()
            } else {
                profileView.timerLabel.text = ISMCallConstants.connectingText
            }
        } else if status == .calling || status == .ringing {
            timer?.invalidate()
            timer = nil
            // Under name while waiting for remote party to join.
            profileView.timerLabel.text = "Calling..."
        } else if let status {
            timer?.invalidate()
            timer = nil
            profileView.timerLabel.text = status.rawValue.capitalized + "..."
        } else {
            timer?.invalidate()
            timer = nil
            profileView.timerLabel.text = "Calling..."
        }

        profileView.profileImageView.setImage(
            urlString: member?.memberProfileImageURL,
            placeholderImage: CircularImagePlaceholder.createCircularInitialsPlaceholder(
                name: member?.memberName ?? "Unknown",
                size: CGSize(width: profileView.profileImageView.bounds.width, height: profileView.profileImageView.bounds.height)
            )
        )
    }
    
    // MARK: - Timer
    private func startTimer() {
        timer?.invalidate()
        let scheduled = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateAppTimer()
        }
        RunLoop.main.add(scheduled, forMode: .common)
        timer = scheduled
    }
    
    //    private func updateTimer() {
    //        seconds += 1
    //        let minutes = seconds / 60
    //        let remainingSeconds = seconds % 60
    //        timerLabel.text = String(format: "%02d:%02d", minutes, remainingSeconds)
    //    }
    func updateAppTimer() {
        guard let startTime = startTime else {
            // Call has not started yet, do nothing
            return
        }
        
        let elapsedTime = Date().timeIntervalSince(startTime)
        // Update your app's timer display with the elapsed time
        let minutes = Int(elapsedTime / 60)
        let seconds = Int(elapsedTime) % 60
        profileView.timerLabel.text = String(format: "%02d:%02d", minutes, seconds)
        // print("Timer: \(timerString)")
    }
}

class ProfileView: UIView {

    let topSpaceView = UIView()
    let nameLabel = UILabel()
    let timerLabel = UILabel()
    let profileImageView = UIImageView()
    var stackView = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }
    
    private func setupView() {
        stackView = UIStackView(arrangedSubviews: [topSpaceView,profileImageView, nameLabel, timerLabel])
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)
        
        topSpaceView.heightAnchor.constraint(equalToConstant: 100).isActive = true
        
        nameLabel.textAlignment = .center
        timerLabel.textAlignment = .center
        nameLabel.textColor = .white
        timerLabel.textColor = .white
        nameLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        timerLabel.font = .systemFont(ofSize: 16, weight: .regular)
        
        profileImageView.layer.cornerRadius = 50
        profileImageView.clipsToBounds = true
        profileImageView.layer.borderWidth = 2.0
        profileImageView.layer.borderColor = UIColor.white.cgColor
        
        profileImageView.widthAnchor.constraint(equalToConstant: 100).isActive = true
        profileImageView.heightAnchor.constraint(equalToConstant: 100).isActive = true
        
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: self.topAnchor, constant: 20),
            stackView.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -20)
        ])
    }
}
