//
// OMEMOModule.swift
//
// TigaseSwift OMEMO
// Copyright (C) 2019 "Tigase, Inc." <office@tigase.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. Look for COPYING file in the top folder.
// If not, see https://www.gnu.org/licenses/.
//

import Foundation
import TigaseSwift
import libsignal

extension XmppModuleIdentifier {
    public static var omemo: XmppModuleIdentifier<OMEMOModule> {
        return OMEMOModule.IDENTIFIER;
    }
}

open class OMEMOModule: AbstractPEPModule, XmppModule {
    
    public static let ID = "omemo";
    public static let IDENTIFIER = XmppModuleIdentifier<OMEMOModule>();
    public static let XMLNS = "in.securesignal.secure.service"
       // "eu.siacs.conversations.axolotl";
    public static let DEVICES_LIST_NODE = "in.securesignal.secure.service.devicelist"
        //"eu.siacs.conversations.axolotl.devicelist";
    
    public let id: String = ID;

    // Default body to set for OMEMO encrypted messages
    open var defaultBody: String? = "I sent you an OMEMO encrypted message but your client doesn’t seem to support that.";
    
    public override var isPepAvailable: Bool {
        didSet {
            if isPepAvailable {
                publishDeviceBundleIfNeeded() {
                    self.publishDeviceIdIfNeeded();
                    if let context = self.context {
                        context.sessionObject.setProperty(OMEMOModule.XMLNS + ".bundle", value: true);
                    }
                }
            }
        }
    }

    public let criteria = Criteria.empty();

    public let features: [String] = [OMEMOModule.DEVICES_LIST_NODE + "+notify"];
    
    public let engine: AES_GCM_Engine;
    public let signalContext: SignalContext;
    public let storage: SignalStorage;
    fileprivate let devicesQueue: DispatchQueue = DispatchQueue(label: "omemo_devices_dispatch_queue");
    fileprivate var devices: [BareJID: [Int32]] = [:];
    fileprivate var devicesFetchError: [BareJID: [Int32]] = [:];

    public var isReady: Bool {
        return isPepAvailable && (context?.sessionObject.getProperty(OMEMOModule.DEVICES_LIST_NODE, defValue: false) ?? false) && (context?.sessionObject.getProperty(OMEMOModule.XMLNS + ".bundle", defValue: false) ?? false);
    }
    
    public func isAvailable(for jid: BareJID) -> Bool {
        return (!(self.devicesQueue.sync(execute: { self.devices[jid] })?.isEmpty ?? true)) || !self.storage.sessionStore.allDevices(for: jid.stringValue, activeAndTrusted: true).isEmpty;
    }
    
    public init(aesGCMEngine: AES_GCM_Engine, signalContext: SignalContext, signalStorage: SignalStorage) {
        self.signalContext = signalContext;
        self.storage = signalStorage;
        self.engine = aesGCMEngine;
        super.init();
    }
    
    public func regenerateKeys(wipe: Bool = false) -> Bool {
        let regenerated = self.storage.regenerateKeys(wipe: wipe);
        if regenerated && isPepAvailable {
            self.publishDeviceBundle(currentBundle: nil) {
                self.publishDeviceIdIfNeeded();
            }
        }
        return regenerated;
    }
    
    public func devices(for jid: BareJID) -> [Int32]? {
        guard let devices = self.devicesQueue.sync(execute: { self.devices[jid] }) else {
            return nil;
        }
        guard let failed = self.devicesFetchError[jid] else {
            return devices;
        }
        return devices.filter({ (deviceId) -> Bool in
            return !failed.contains(deviceId);
        });
    }

    
    public func process(stanza: Stanza) throws {
        throw ErrorCondition.feature_not_implemented;
    }
    
    public func decode(message: Message) -> DecryptionResult<Message, SignalError> {
        guard let from = message.from?.bareJid else {
            return .failure(.invalidArgument);
        }
        return self.decode(message: message, from: from);
    }
    
    
    public func decode(message: Message, from: BareJID) -> DecryptionResult<Message, SignalError> {
        guard let context = context else {
            return .failure(.unknown);
        }
//"encrypted"
        guard let encryptedEl = message.findChild(name: "label", xmlns: OMEMOModule.XMLNS) else {
            return .failure(SignalError.notEncrypted);
        }
        
        guard let headerEl = encryptedEl.findChild(name: "header"), let sid = UInt32(headerEl.getAttribute("sid") ?? "") else {
            return .failure(.invalidArgument);
        }
        
        let localDeviceIdStr = String(signalContext.storage.identityKeyStore.localRegistrationId());
        
        guard headerEl.findChild(where: { (el) -> Bool in
            return el.name == "key" && el.getAttribute("rid") == localDeviceIdStr;
        }) != nil else {
            guard context.userBareJid != from || sid != signalContext.storage.identityKeyStore.localRegistrationId() else {
                return .failure(.duplicateMessage);
            }
            guard encryptedEl.findChild(name: "message-body") != nil else {
                return .failure(.duplicateMessage);
            }
            return .failure(.invalidMessage);
        }
        
        let possibleKeys = headerEl.getChildren(where: { (el) -> Bool in
            return el.name == "key" && el.getAttribute("rid") == localDeviceIdStr;
        }).map({ (keyEl) -> Result<(SignalAddress, Data, Bool), SignalError> in
            guard let keyElValue = keyEl.value, let key = Data(base64Encoded: keyElValue) else {
                return .failure(.invalidArgument);
            }
            let prekey = "true" == keyEl.getAttribute("prekey") || keyEl.getAttribute("prekey") == "1";
            let address = SignalAddress(name: from.stringValue, deviceId: Int32(bitPattern: sid));
            guard let session = SignalSessionCipher(withAddress: address, andContext: self.signalContext) else {
                return .failure(SignalError.noMemory);
            }
            switch session.decrypt(key: SignalSessionCipher.Key(key: key,deviceId: Int32(bitPattern: sid), prekey: prekey)) {
            case .failure(let error):
                return .failure(error);
            case .success(let data):
                return .success((address, data, prekey));
            }
        });
        
        guard let possibleKey = possibleKeys.first(where: { (result) -> Bool in
            switch result {
            case .failure(_):
                return false;
            case .success(_):
                return true;
            }
        }) else {
            if let err = possibleKeys.first {
                switch err {
                case .failure(let error):
                    return .failure(error);
                case .success(_):
                    return .failure(.unknown);
                }
            } else {
                guard encryptedEl.findChild(name: "message-body") != nil else {
                    return .failure(.duplicateMessage);
                }
                return .failure(.invalidMessage);
            }
        }
        
        switch possibleKey {
        case .failure(let error):
            return .failure(error);
        case .success(let item):
            message.removeChild(encryptedEl);

            var (address, decodedKey, prekey) = item;
            
            if prekey {
                // pre key was removed so we need to republish the bundle!
                self.publishDeviceIdIfNeeded();
            }

            var auth: Data? = nil;
            if decodedKey.count >= 32 {
                auth = decodedKey.subdata(in: 16..<decodedKey.count);
                decodedKey = decodedKey.subdata(in: 0..<16);
            }
            
            guard let ivStr = headerEl.findChild(name: "iv")?.value, let iv = Data(base64Encoded: ivStr) else {
                return .failure(.invalidArgument);
            }
            
            guard let payloadValue = encryptedEl.findChild(name: "message-body")?.value, let payload = Data(base64Encoded: payloadValue) else {
                return .successTransportKey(decodedKey, iv: iv);
            }


            var decoded = Data();
            guard engine.decrypt(iv: iv, key: decodedKey, encoded: payload, auth: auth, output: &decoded) else {
                print("decoding of encrypted message failed!");
                return .failure(.invalidMac);
            }
            
            let body = String(data: decoded, encoding: .utf8);
            message.body = body;
            
            if let content = body, content.starts(with: "aesgcm://"), URLComponents(string: content) != nil {
                message.oob = content;
            }

            _ = storage.identityKeyStore.setStatus(active: true, forIdentity: address);
            return .successMessage(message, fingerprint: storage.identityKeyStore.identityFingerprint(forAddress: address));
        }
    }
    
    public func encode(message: Message, withStoreHint: Bool = true, completionHandler: @escaping (EncryptionResult<Message, SignalError>)->Void) {
        guard let jid = message.to?.bareJid else {
            completionHandler(.failure(.noDestination));
            return;
        }

        encode(message: message, for: [jid], withStoreHint: withStoreHint, completionHandler: completionHandler);
    }
    
    public func addresses(for jids: [BareJID], completionHandler: @escaping(Result<[SignalAddress],SignalError>)->Void) {
        guard let pubsubModule: PubSubModule = context?.module(.pubsub) else {
            completionHandler(.failure(.unknown));
            return;
        }
        let group = DispatchGroup();
        var addresses: [SignalAddress] = [];
        for jid in jids {
            if let devices = self.devices(for: jid) {
                addresses.append(contentsOf: devices.map({ SignalAddress(name: jid.stringValue, deviceId: $0) }));
                for address in addresses.filter({ !self.storage.sessionStore.containsSessionRecord(forAddress: $0) }) {
                    group.enter();
                    self.buildSession(forAddress: address, completionHandler: {
                        group.leave();
                    })
                }
            } else {
                group.enter();
                pubsubModule.retrieveItems(from: jid, for: OMEMOModule.DEVICES_LIST_NODE, limit: .lastItems(1), completionHandler: { result in
                    switch result {
                    case .success(let items):
                        print("got published devices from:", jid, ", ", items.items.first as Any);
                        if let listEl = items.items.first?.payload, listEl.name == "list" && listEl.xmlns == "in.securesignal.secure.service" {
                            let knownActiveDevices: [Int32] = listEl.mapChildren(transform: { $0.getAttribute("id") }).compactMap({ Int32($0) });
                                
                            
                            let allDevices = self.storage.sessionStore.allDevices(for: jid.stringValue, activeAndTrusted: true);
                            allDevices.filter { (id) -> Bool in
                                return !knownActiveDevices.contains(id);
                                }.forEach { (deviceId) in
                                    _ = self.storage.identityKeyStore.setStatus(active: false, forIdentity: SignalAddress(name: jid.stringValue, deviceId: deviceId));
                            }
                            
                            knownActiveDevices.filter { (id) -> Bool in
                                return !allDevices.contains(id);
                                }.forEach { (deviceId) in
                                    // TODO: we should enable this device key if we have its identity!
                                    _ = self.storage.identityKeyStore.setStatus(active: true, forIdentity: SignalAddress(name: jid.stringValue, deviceId: deviceId));
                            }
                            addresses.append(contentsOf: knownActiveDevices.map({ SignalAddress(name: jid.stringValue, deviceId: $0) }));
                        }
                        
                        // should we start fetching sessions here? without waiting for all JIDs to return? should improve performance
                        for address in addresses.filter({ !self.storage.sessionStore.containsSessionRecord(forAddress: $0) }) {
                            group.enter();
                            self.buildSession(forAddress: address, completionHandler: {
                                group.leave();
                            })
                        }
                    case .failure(_):
                        break;
                    }
                    group.leave();
                })
            }
        }
        group.notify(queue: DispatchQueue.main, execute: {
            // we finished address retrieval..
            completionHandler(.success(addresses));
        })
    }
    
    public func encode(message: Message, for jids: [BareJID], withStoreHint: Bool = true, completionHandler: @escaping (EncryptionResult<Message, SignalError>)->Void) {
        
        addresses(for: jids, completionHandler: { result in
            switch result {
            case .failure(let error):
                completionHandler(.failure(error));
            case .success(let addresses):
                if addresses.isEmpty {
                    completionHandler(.failure(.noSession));
                } else {
                    self.encode(message: message, forAddresses: addresses, withStoreHint: withStoreHint, completionHandler: completionHandler);
                }
            }
            
        })
    }
     
    public func encode(message: Message, forAddresses addresses: [SignalAddress], withStoreHint: Bool = true, completionHandler: @escaping (EncryptionResult<Message, SignalError>)->Void) {

        let result = self._encode(message: message, for: addresses);
        
        switch result {
        case .successMessage(let encodedMessage, _):
            encodedMessage.body = self.defaultBody;
            if withStoreHint {
                encodedMessage.addChild(Element(name: "store", xmlns: "urn:xmpp:hints"));
            }
        default:
            break;
        }
        
        completionHandler(result);
    }
    
    public func decryptFile(url localUrl: URL, fragment: String) -> Result<Data,ErrorCondition> {
        guard let data = try? Data(contentsOf: localUrl) else {
            return .failure(ErrorCondition.item_not_found);
        }

        return decryptFile(data: data, fragment: fragment);
    }
    
    public func decryptFile(data inData: Data, fragment: String) -> Result<Data,ErrorCondition> {
        guard fragment.count % 2 == 0 && fragment.count > 64 && inData.count > 32 else {
            return .failure(.not_acceptable);
        }
        
        let fragmentData = fragment.map { (c) -> UInt8 in
            return UInt8(c.hexDigitValue ?? 0);
        };

        let ivLen = fragmentData.count - (32 * 2);
        
        var iv = Data();
        var key = Data();
        
        for i in 0..<(ivLen/2) {
            iv.append(fragmentData[i*2]*16 + fragmentData[i*2+1]);
        }
        for i in (ivLen/2)..<(fragmentData.count/2) {
            key.append(fragmentData[i*2]*16 + fragmentData[i*2+1]);
        }
        
        let tag = inData.subdata(in: inData.count-16..<inData.count);
        let encodedData = inData.subdata(in: 0..<(inData.count-16));
        var decoded = Data();
        
        guard engine.decrypt(iv: iv, key: key, encoded: encodedData, auth: tag, output: &decoded) else {
            return .failure(.not_acceptable);
        }
        
        return .success(decoded);
    }
    
    public func encryptFile(url: URL) -> Result<(Data, String),ErrorCondition> {
        guard let data = try? Data(contentsOf: url) else {
            return .failure(ErrorCondition.item_not_found);
        }

        return encryptFile(data: data);
    }
    
    public func encryptFile(data: Data) -> Result<(Data, String),ErrorCondition> {
        var iv = Data(count: 12);
        iv.withUnsafeMutableBytes { (bytes) -> Void in
            _ = SecRandomCopyBytes(kSecRandomDefault, 12, bytes.baseAddress!);
        }

        var key = Data(count: 32);
        key.withUnsafeMutableBytes { (bytes) -> Void in
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!);
        }

        var encryptedBody = Data();
        var tag = Data();

        guard engine.encrypt(iv: iv, key: key, message: data, output: &encryptedBody, tag: &tag) else {
            return .failure(.not_acceptable);
        }
        
        let combinedKey = iv + key;

        return .success((encryptedBody + tag, combinedKey.map({ String(format: "%02x", $0) }).joined()));
    }
    
    private func _encode(message: Message, for remoteAddresses: [SignalAddress]) -> EncryptionResult<Message,SignalError> {
        guard let context = self.context else {
            return .failure(.unknown);
        }
        
        let body = message.body!;

        var iv = Data(count: 12);
        iv.withUnsafeMutableBytes { (bytes) -> Void in
            _ = SecRandomCopyBytes(kSecRandomDefault, 12, bytes.baseAddress!);
        }

        var key = Data(count: 16);
        key.withUnsafeMutableBytes { (bytes) -> Void in
            _ = SecRandomCopyBytes(kSecRandomDefault, 16, bytes.baseAddress!);
        }
        
        var encryptedBody = Data();
        var tag = Data();
        
        let data = body.data(using: .utf8)!;
        guard engine.encrypt(iv: iv, key: key, message: data, output: &encryptedBody, tag: &tag) else {
            return .failure(.notEncrypted);
        }
        
        var combinedKey = key;
        combinedKey.append(tag);
        
        let encryptedEl = Element(name: "label", xmlns: OMEMOModule.XMLNS);
        encryptedEl.addChild(Element(name: "message-body", cdata: encryptedBody.base64EncodedString()));
        
        let header = Element(name: "header");
        header.setAttribute("sid", value: String(signalContext.storage.identityKeyStore.localRegistrationId()));
        encryptedEl.addChild(header);
        
        let localAddresses = storage.sessionStore.allDevices(for: context.userBareJid.stringValue, activeAndTrusted: true).map({ (deviceId) -> SignalAddress in
            return SignalAddress(name: context.userBareJid.stringValue, deviceId: deviceId);
        });
        let destinations: Set<SignalAddress> = Set(remoteAddresses + localAddresses);
        header.addChildren(destinations.map({ (addr) -> Result<SignalSessionCipher.Key,SignalError> in
                // TODO: maybe we should cache this session?
                guard let session = SignalSessionCipher(withAddress: addr, andContext: self.signalContext) else {
                    return .failure(.noMemory);
                }
                return session.encrypt(data: combinedKey);
            }).map({ (result) -> Element? in
                switch result {
                case .success(let key):
                    let keyEl = Element(name: "key", cdata: key.key.base64EncodedString());
                    keyEl.setAttribute("rid", value: String(key.deviceId));
                    if key.prekey {
                        keyEl.setAttribute("prekey", value: "true");
                    }
                    return keyEl;
                case .failure(_):
                    return nil;
                }
            }).filter({ (el) -> Bool in
                return el != nil;
            }).map({ el -> Element in
                return el!;
            }));
        header.addChild(Element(name: "iv", cdata: iv.base64EncodedString()));

        message.body = nil;
        message.addChild(Element(name: "store", xmlns: "urn:xmpp:hints"));
        message.addChild(encryptedEl);
        
        let fingerprint = storage.identityKeyStore.identityFingerprint(forAddress: SignalAddress(name: context.userBareJid.stringValue, deviceId: Int32(bitPattern: storage.identityKeyStore.localRegistrationId())));
        
        return .successMessage(message, fingerprint: fingerprint);
    }
    
    open override func onItemNotification(notification: PubSubModule.ItemNotification) {
        if notification.node == OMEMOModule.DEVICES_LIST_NODE, let from = notification.message.from?.bareJid {
            switch notification.action {
            case .published(let item):
                checkAndPublishDevicesListIfNeeded(jid: from, list: item.payload)
            default:
                break;
            }
        }
    }
    
    func publishDeviceIdIfNeeded(removeDevicesWithIds: [UInt32]? = nil) {
        guard isPepAvailable, let context = context else {
            return;
        }
        let pepJid = context.userBareJid;
        context.module(.pubsub).retrieveItems(from: pepJid, for: OMEMOModule.DEVICES_LIST_NODE, limit: .lastItems(1), completionHandler: { result in
            switch result {
            case .success(let items):
                print("got published devices:", items.items.first as Any);
                self.checkAndPublishDevicesListIfNeeded(jid: pepJid, list: items.items.first?.payload, removeDevicesWithIds: removeDevicesWithIds);
            case .failure(let pubsubError):
                guard pubsubError.error == .item_not_found || pubsubError.error == .internal_server_error() else {
                    return;
                }
                self.checkAndPublishDevicesListIfNeeded(jid: pepJid, list: nil);
            }
        });
    }
        
    fileprivate func checkAndPublishDevicesListIfNeeded(jid: BareJID, list input: Element?, removeDevicesWithIds: [UInt32]? = nil) {
        guard let context = context else {
            return;
        }

        let pubsubModule = context.module(.pubsub);
        var listEl = input;

        if listEl?.name != "list" || listEl?.xmlns != "in.securesignal.secure.service" {
            listEl = Element(name: "list", xmlns: "in.securesignal.secure.service");
        }
        
        
        let me = context.userBareJid == jid;
        
        if me {
            var changed = false;
            
            if removeDevicesWithIds != nil && listEl != nil {
                let deviceIds = removeDevicesWithIds!.map { (deviceId) -> String in
                    return String(deviceId);
                }
                listEl!.removeChildren(where: { (el) -> Bool in
                    guard let id = el.getAttribute("id") else {
                        return false;
                    }
                    return deviceIds.contains(id);
                });
                changed = true;
            }
        
            let ourDeviceId = self.storage.identityKeyStore.localRegistrationId();
            let ourDeviceIdStr = String(ourDeviceId);
            if listEl?.findChild(where: { (deviceEl) -> Bool in
                deviceEl.getAttribute("id") == ourDeviceIdStr;
            }) == nil {
                listEl?.addChild(Element(name: "device", attributes: ["id": ourDeviceIdStr]));
                changed = true;
            }
        
            if changed {
                let publishOptions = JabberDataElement(type: .submit);
                publishOptions.addField(TextSingleField(name: "pubsub#access_model", value: "open"));
                pubsubModule.publishItem(at: jid, to: OMEMOModule.DEVICES_LIST_NODE, itemId: "current", payload: listEl!, publishOptions: publishOptions, completionHandler: { result in
                    switch result {
                    case .success(_):
                        print("device id:", ourDeviceIdStr, " successfully registered!");
                    case .failure(let pubsubError):
                        print("item registration failed!");
                        if pubsubError.error == .conflict() {
                            pubsubModule.retrieveNodeConfiguration(from: jid, node: OMEMOModule.DEVICES_LIST_NODE, completionHandler: { result in
                                switch result {
                                case .success(let form):
                                    guard let field: ListSingleField = form.getField(named: "pubsub#access_model") else {
                                        return;
                                    }
                                    field.value = "open";
                                    pubsubModule.configureNode(at: jid, node: OMEMOModule.DEVICES_LIST_NODE, with: form, completionHandler: { result in
                                        switch result {
                                        case .success(_):
                                            pubsubModule.publishItem(at: jid, to: OMEMOModule.DEVICES_LIST_NODE, itemId: "current", payload: listEl!, publishOptions: publishOptions, completionHandler: { result in
                                                switch result {
                                                case .success(_):
                                                    print("device id:", ourDeviceIdStr, " successfully registered 2!");
                                                case .failure(let error):
                                                    print("item registration failed 2! \(error)");
                                                }
                                            });
                                        case .failure(let error):
                                            print("node reconfiguration failed! \(error)");
                                        }
                                    });
                                case .failure(let error):
                                    print("node configuration retrieval failed! \(error)");
                                }
                            });
                        }
                    }
                });
            } else {
                context.sessionObject.setProperty(OMEMOModule.DEVICES_LIST_NODE, value: true);
            }
        }
        
        let knownActiveDevices = listEl!.mapChildren(transform: { (el) -> Int32? in
            guard let id = el.getAttribute("id") else {
                return nil;
            }
            return Int32(id);
        });
        
        let allDevices = storage.sessionStore.allDevices(for: jid.stringValue, activeAndTrusted: true);
        allDevices.filter { (id) -> Bool in
            return !knownActiveDevices.contains(id);
            }.forEach { (deviceId) in
                _ = storage.identityKeyStore.setStatus(active: false, forIdentity: SignalAddress(name: jid.stringValue, deviceId: deviceId));
        }
        
        knownActiveDevices.filter { (id) -> Bool in
            return !allDevices.contains(id);
            }.forEach { (deviceId) in
                // TODO: we should enable this device key if we have its identity!
                _ = storage.identityKeyStore.setStatus(active: true, forIdentity: SignalAddress(name: jid.stringValue, deviceId: deviceId));
        }
        
        if me {
            knownActiveDevices.forEach { (deviceId) in
                guard deviceId != self.storage.identityKeyStore.localRegistrationId() else {
                    return;
                }
                let address = SignalAddress(name: jid.stringValue, deviceId: deviceId);
                if !self.storage.sessionStore.containsSessionRecord(forAddress: address) {
                    // we do not have a session, so we need to build one!
                    self.buildSession(forAddress: address);
                }
            }
        }
        self.devicesQueue.async {
            self.devices[jid] = knownActiveDevices;
            self.fire(AvailabilityChangedEvent(sessionObject: context.sessionObject, jid: jid));
        }
    }

    func publishDeviceBundleIfNeeded(completionHandler: @escaping ()->Void) {
        guard let pepJid = context?.userBareJid, let pubsubModule = context?.module(.pubsub) else {
            return;
        }
        
        pubsubModule.retrieveItems(from: pepJid, for: bundleNode(for: storage.identityKeyStore.localRegistrationId()), limit: .items(withIds: ["current"]), completionHandler: { result in
            switch result {
            case .success(let items):
                self.publishDeviceBundle(currentBundle: items.items.first?.payload, completionHandler: completionHandler);
            case .failure(let pubsubError):
                guard pubsubError.error == .item_not_found || pubsubError.error == .internal_server_error() else {
                    return;
                }
                self.publishDeviceBundle(currentBundle: nil, completionHandler: completionHandler);
            }
        });
    }
    
    public func removeDevices(withIds: [Int32]) {
        guard let pepJid = context?.userBareJid, let pubsubModule = context?.module(.pubsub) else {
            return;
        }
        
        let ids = withIds.map { (deviceId) -> UInt32 in
            return UInt32(bitPattern: deviceId);
        }
        
        withIds.forEach { deviceId in
            _ = self.storage.identityKeyStore.setStatus(active: false, forIdentity: SignalAddress(name: pepJid.stringValue, deviceId: deviceId));
            
            pubsubModule.deleteNode(from: pepJid, node: bundleNode(for: UInt32(bitPattern: deviceId)), completionHandler: nil);
        }
        
        self.publishDeviceIdIfNeeded(removeDevicesWithIds: ids);
    }
    
    fileprivate func signedPreKey(regenerate: Bool = false) -> SignalSignedPreKey? {
        let signedPreKeyId = storage.signedPreKeyStore.countSignedPreKeys();
        var signedPreKey: SignalSignedPreKey? = nil;
        if (!regenerate) && (signedPreKeyId != 0) {
            if let data = signalContext.storage.signedPreKeyStore.loadSignedPreKey(withId: UInt32(signedPreKeyId)) {
                signedPreKey = SignalSignedPreKey(fromSerializedData: data);
            }
        }
        
        if signedPreKey == nil {
            let identityKeyPair = storage.identityKeyStore.keyPair()!;
            print("regenerating signed pre key!");
            signedPreKey = signalContext.generateSignedPreKey(withIdentity: identityKeyPair, signedPreKeyId: UInt32(signedPreKeyId + 1))
            guard signedPreKey != nil else {
                return nil;
            }
            guard signalContext.storage.signedPreKeyStore.storeSignedPreKey(signedPreKey!.serializedData!, withId: signedPreKey!.preKeyId) else {
                return nil;
            }
        }
        return signedPreKey;
    }
    
//    fileprivate func publishDeviceBundleNoKeys(regenerate: Bool = false, completionHandler: @escaping ()->Void) {
//        if let signedPreKey = signedPreKey(regenerate: regenerate) {
//            let preKeys = signalContext.generatePreKeys(withStartingPreKeyId: 0, count: 20);
//            preKeys.forEach { (preKey) in
//                _ = self.storage.preKeyStore.storePreKey(preKey.serializedData!, withId: preKey.preKeyId);
//            }
//            publishDeviceBundle(signedPreKey: signedPreKey, preKeys: preKeys, completionHandler: completionHandler);
//        }
//    }

    fileprivate func publishDeviceBundle(currentBundle: Element?, completionHandler: @escaping ()->Void) {
        guard let identityPublicKey = storage.identityKeyStore.keyPair()?.publicKey?.base64EncodedString() else {
            completionHandler();
            return;
        }

        var flush: Bool = currentBundle == nil;
        if !flush {
            flush = identityPublicKey != currentBundle?.findChild(name: "identityKey")?.value;
        }
        
        if let signedPreKey = self.signedPreKey(regenerate: flush), let signedPreKeyBase64 = signedPreKey.publicKeyData?.base64EncodedString() {
            let signatureBase64 = signedPreKey.signature.base64EncodedString();
            var changed = flush || signedPreKeyBase64 != currentBundle?.findChild(name: "signedPreKeyPublic")?.value || signatureBase64 != currentBundle?.findChild(name: "signedPreKeySignature")?.value;
            
            let currentKeys = currentBundle?.findChild(name: "prekeys")?.mapChildren(transform: { (preKeyEl) -> UInt32? in
                guard let preKeyId = preKeyEl.getAttribute("preKeyId") else {
                    return nil;
                }
                return UInt32(preKeyId);
            });
            
            var validKeys = currentKeys?.map({ (preKeyId) -> SignalPreKey? in
                guard let key = self.storage.preKeyStore.loadPreKey(withId: preKeyId) else {
                    return nil;
                }
                return SignalPreKey(fromSerializedData: key);
            }).filter({ (preKey) -> Bool in
                return preKey != nil;
            }).map({ preKey -> SignalPreKey in
                return preKey!;
            }) ?? [];
            let needKeys = 100 - validKeys.count;
            if needKeys > 0 {
                changed = true;
                let currentPreKeyId = self.storage.preKeyStore.currentPreKeyId();
                var newKeys = self.signalContext.generatePreKeys(withStartingPreKeyId: currentPreKeyId + 1, count: UInt32(needKeys));
                newKeys = newKeys.filter { (key) in
                    self.storage.preKeyStore.storePreKey(key.serializedData!, withId: key.preKeyId);
                };
                validKeys = validKeys + newKeys;
            }

            if changed {
                // something has changed, we need to publish new bundle!
                publishDeviceBundle(signedPreKey: signedPreKey, preKeys: validKeys, completionHandler: completionHandler);
            } else {
                completionHandler();
            }
        }
    }

    func publishDeviceBundle(signedPreKey: SignalSignedPreKey, preKeys: [SignalPreKey], completionHandler: @escaping ()->Void) {
        let identityKeyPair = storage.identityKeyStore.keyPair()!;
        
        let bundleEl = Element(name: "bundle", xmlns: OMEMOModule.XMLNS);
        bundleEl.addChild(Element(name: "signedPreKeyPublic", cdata: signedPreKey.publicKeyData!.base64EncodedString(), attributes: ["signedPreKeyId": String(signedPreKey.preKeyId)]));
        bundleEl.addChild(Element(name: "signedPreKeySignature", cdata: signedPreKey.signature.base64EncodedString()));
        bundleEl.addChild(Element(name: "identityKey", cdata: identityKeyPair.publicKey!.base64EncodedString()));
        let preKeysElems = preKeys.map({ (preKey) -> Element in
            return Element(name: "preKeyPublic", cdata: preKey.serializedPublicKey!.base64EncodedString(), attributes: ["preKeyId": String(preKey.preKeyId)]);
        });
        bundleEl.addChild(Element(name: "prekeys", children: preKeysElems));
        
        let publishOptions = JabberDataElement(type: .submit);
        publishOptions.addField(TextSingleField(name: "pubsub#access_model", value: "open"));
        
        guard let pubsubModule = context?.module(.pubsub) else {
            return;
        }
        pubsubModule.publishItem(at: nil, to: bundleNode(for: storage.identityKeyStore.localRegistrationId()), itemId: "current", payload: bundleEl, publishOptions: publishOptions, completionHandler: { result in
            switch result {
            case .success(_):
                print("published public keys!");
                completionHandler();
            case .failure(let pubsubError):
                print("cound not publish keys:", pubsubError);
            }
        });
    }
    
    open func buildSession(forAddress address: SignalAddress, retryNo: Int = 0, completionHandler: (()->Void)? = nil) {
        let pepJid = BareJID(address.name);
        guard let pubsubModule: PubSubModule = context?.module(.pubsub) else {
            return;
        }
        pubsubModule.retrieveItems(from: pepJid, for: bundleNode(for: UInt32(bitPattern: address.deviceId)), limit: .lastItems(1), completionHandler: { result in
            switch result {
            case .success(let items):
                guard let bundle = OMEMOBundle(from: items.items.first?.payload) else {
                    print("could not create a bundle!");
                    self.markDeviceAsFailed(for: pepJid, andDeviceId: address.deviceId);
                    completionHandler?();
                    return;
                }
                
                let preKey = bundle.preKeys[Int.random(in: 0..<bundle.preKeys.count)];
                if let preKeyBundle = SignalPreKeyBundle(registrationId: 0, deviceId: address.deviceId, preKey: preKey, bundle: bundle) {
                    if let builder = SignalSessionBuilder(withAddress: address, andContext: self.signalContext) {
                        if builder.processPreKeyBundle(bundle: preKeyBundle) {
                            print("signal session established!");
                        } else {
                            print("building session failed!");
                        }
                    } else {
                        print("unable to create builder!");
                    }
                } else {
                    print("unable to create pre key bundle!");
                    self.markDeviceAsFailed(for: pepJid, andDeviceId: address.deviceId);
                }
                completionHandler?();
            case .failure(let pubsubError):
                if pubsubError.error == .item_not_found && retryNo < 5 {
                    DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 1.0, execute: {
                        self.buildSession(forAddress: address, retryNo: retryNo + 1, completionHandler: completionHandler);
                    })
                } else {
                    self.markDeviceAsFailed(for: pepJid, andDeviceId: address.deviceId);
                    completionHandler?();
                }
            }
        });
    }
    
    fileprivate func markDeviceAsFailed(for jid: BareJID, andDeviceId deviceId: Int32) {
        var devices = self.devicesFetchError[jid] ?? [];
        if !devices.contains(deviceId) {
            devices.append(deviceId);
            self.devicesFetchError[jid] = devices;
        }
    }
    
    func bundleNode(for deviceId: UInt32) -> String {
        return "in.securesignal.secure.service.bundles:\(deviceId)";
    }
    
    open class OMEMOBundle {
        
        let preKeys: [OMEMOPreKey];
        
        let signedPreKeyId: UInt32;
        let signedPreKeyPublic: Data;
        let identityKey: Data;
        let signature: Data;
        
        init?(from: Element?) {
            guard let el = from, el.name == "bundle" && el.xmlns == OMEMOModule.XMLNS else {
                return nil;
            }
            
            guard let preKeys = el.findChild(name: "prekeys")?.mapChildren(transform: { (el) -> OMEMOPreKey? in
                return OMEMOPreKey(from: el);
            }), !preKeys.isEmpty else {
                return nil;
            }
            
            guard let signedKeyPublic = el.findChild(name: "signedPreKeyPublic"), let signedPreKeyIdStr = signedKeyPublic.getAttribute("signedPreKeyId"), let signedPreKeyId = UInt32(signedPreKeyIdStr), let signedKeyPublicValue = signedKeyPublic.value, let signedKeyPublicData = Data(base64Encoded: signedKeyPublicValue, options: [.ignoreUnknownCharacters]) else {
                return nil;
            }

            guard let identityKeyValue = el.findChild(name: "identityKey")?.value, let identityKeyData = Data(base64Encoded: identityKeyValue, options: [.ignoreUnknownCharacters]) else {
                return nil;
            }

            guard let signatureValue = el.findChild(name: "signedPreKeySignature")?.value, let signatureData = Data(base64Encoded: signatureValue, options: [.ignoreUnknownCharacters]) else {
                return nil;
            }
            
            self.signedPreKeyId = signedPreKeyId;
            self.signedPreKeyPublic = signedKeyPublicData;
            self.signature = signatureData;
            self.identityKey = identityKeyData;
            self.preKeys = preKeys;
        }
        
    }
    
    open class OMEMOPreKey {
        
        public let preKeyId: UInt32;
        public let data: Data;
        
        public convenience init?(from: Element) {
            guard from.name == "preKeyPublic", let value = from.value, let preKeyIdStr = from.getAttribute("preKeyId") else {
                return nil;
            }
            guard let data = Data(base64Encoded: value, options: [.ignoreUnknownCharacters]), let preKeyId = UInt32(preKeyIdStr) else {
                return nil;
            }
            
            self.init(data: data, preKeyId: preKeyId);
        }

        public init(data: Data, preKeyId: UInt32) {
            self.data = data;
            self.preKeyId = preKeyId;
        }

    }
    
    open class AvailabilityChangedEvent: Event {
        
        public static let TYPE = AvailabilityChangedEvent();
        
        public let type = "OMEMOAvailabilityChangedEvent";
        
        public let sessionObject: SessionObject!;
        public var account: BareJID {
            return sessionObject.context.userBareJid;
        }
        public let jid: BareJID!;
        
        init() {
            self.sessionObject = nil;
            self.jid = nil;
        }
        
        public init(sessionObject: SessionObject, jid: BareJID) {
            self.sessionObject = sessionObject;
            self.jid = jid;
        }
        
    }
}

public protocol AES_GCM_Engine {
    
    func encrypt(iv: Data, key: Data, message: Data, output: UnsafeMutablePointer<Data>?, tag: UnsafeMutablePointer<Data>?) -> Bool;
    
    func decrypt(iv: Data, key: Data, encoded: Data, auth tag: Data?, output: UnsafeMutablePointer<Data>?) -> Bool;
    
}

public enum EncryptionResult<Success, Failure> {
    case successMessage(_ success: Success, fingerprint: String?)
    case failure(_ error: Failure)
}

public enum DecryptionResult<Success, Failure> {
    case successMessage(_ success: Success, fingerprint: String?)
    case successTransportKey(_ key: Data, iv: Data)
    case failure(_ error: Failure)
}
