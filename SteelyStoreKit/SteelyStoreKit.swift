//
//  SteelyStoreKit.swift
//  SteelyStoreKit
//
//  Created by Peter Steele on 11/21/16.
//  Copyright © 2016 Peter Steele. All rights reserved.
//
//  Converted with Swiftify v1.0.6166 - https://objectivec2swift.com/

import Foundation

import StoreKit

extension Notification.Name {
    static let SteelyStoreKitProductsAvailable = Notification.Name("com.pete.steelystorekit.productsavailable")
    static let SteelyStoreKitProductPurchased = Notification.Name("com.pete.steelystorekit.productspurchased")
    static let SteelyStoreKitProductPurchaseFailed = Notification.Name("com.pete.steelystorekit.productspurchasefailed")
    static let SteelyStoreKitProductPurchaseDeferred = Notification.Name("com.pete.steelystorekit.productspurchasedeferred")
    static let SteelyStoreKitRestoredPurchases = Notification.Name("com.pete.steelystorekit.restoredpurchases")
    static let SteelyStoreKitRestoringPurchasesFailed = Notification.Name("com.pete.steelystorekit.failedrestoringpurchases")
    static let SteelyStoreKitReceiptValidationFailed = Notification.Name("com.pete.steelystorekit.failedvalidatingreceipts")
    static let SteelyStoreKitSubscriptionExpired = Notification.Name("com.pete.steelystorekit.subscriptionexpired")
    static let SteelyStoreKitDownloadProgress = Notification.Name("com.pete.steelystorekit.downloadprogress")
    static let SteelyStoreKitDownloadCompleted = Notification.Name("com.pete.steelystorekit.downloadcompleted")
}

enum SteelyStoreKitError: Error {
    case statusError(domain: NSErrorDomain, status: Int, userInfo: [String: Any])
}

let kSandboxServer = "https://sandbox.itunes.apple.com/verifyReceipt"
let kLiveServer = "https://buy.itunes.apple.com/verifyReceipt"
let kOriginalAppVersionKey = "SKOrigBundleRef"

class SteelyStoreKit: NSObject, SKProductsRequestDelegate, SKPaymentTransactionObserver {
    // MARK: -
    // MARK: Singleton Methods
    var purchaseRecord = [String: Any]()
    var availableProducts: [SKProduct]?
    
    // Obfuscating record key name
    var errorDictionary = [21000: "The App Store could not read the JSON object you provided.",
                           21002: "The data in the receipt-data property was malformed or missing.",
                           21003: "The receipt could not be authenticated.",
                           21004: "The shared secret you provided does not match the shared secret on file for your accunt.",
                           21005: "The receipt server is not currently available.",
                           21006: "This receipt is valid but the subscription has expired.",
                           21007: "This receipt is from the test environment.",
                           21008: "This receipt is from the production environment."]
    
    static let shared: SteelyStoreKit = {
        let sharedKit = SteelyStoreKit()
        SKPaymentQueue.default().add(sharedKit as SKPaymentTransactionObserver)
        sharedKit.restorePurchaseRecord()
        #if os(iOS)
            NotificationCenter.default.addObserver(sharedKit, selector: #selector(SteelyStoreKit.savePurchaseRecord), name: NSNotification.Name.UIApplicationDidEnterBackground, object: nil)
        #else
            NotificationCenter.default.addObserver(sharedKit, selector: #selector(SteelyStoreKit.savePurchaseRecord), name: NSApplicationDidResignActiveNotification, object: nil)
        #endif
        sharedKit.startValidatingReceiptsAndUpdateLocalStore()
        return sharedKit
    }()
    
    // MARK: -
    // MARK: Helpers
    
    class func configs() -> [String: Any] {
        let fileUrl = URL(fileURLWithPath: Bundle.main.resourcePath!).appendingPathComponent("SteelyStoreKitConfigs.plist").relativePath
        if let contents = NSDictionary(contentsOfFile: fileUrl) as? [String: Any] {
            return contents
        } else {
            return [:]
        }
    }
    
    func purchaseRecordFilePath() -> String {
        let documentDirectory = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        return URL(fileURLWithPath: documentDirectory).appendingPathComponent("purchaserecord.plist").absoluteString
    }
    
    func restorePurchaseRecord() {
        if let pR = NSKeyedUnarchiver.unarchiveObject(withFile: self.purchaseRecordFilePath()) {
            purchaseRecord = pR as! [String: Any]
            print("\(purchaseRecord)")
        }
    }
    
    func savePurchaseRecord() {
        var data = NSKeyedArchiver.archivedData(withRootObject: purchaseRecord)
        #if TARGET_OS_IPHONE
            do {
                try data.write(toFile: self.purchaseRecordFilePath(), options: [.atomic, .completeFileProtection])
            } catch _ {
                print("Failed to remember data record")
            }
        #elseif TARGET_OS_MAC
            do {
                try data.write(toFile: self.purchaseRecordFilePath(), options: .atomic)
            } catch _ {
                print("Failed to remember data record")
            }
        #endif
        print("\(self.purchaseRecord)")
    }
    // MARK: -
    // MARK: Feature Management
    
    func isProductPurchased(_ productId: String) -> Bool {
        return purchaseRecord.keys.contains(productId)
    }
    
    func expiryDate(forProduct productId: String) -> Date? {
        if let expiresDateMs = self.purchaseRecord[productId] {
            if expiresDateMs is NSNull {
                // a recently purchased subscription
                // TODO: fix, must return the actual length of time of the subscription
                return Calendar.current.date(byAdding: .month, value: 1, to: Date())!
            } else {
                return Date(timeIntervalSince1970: Double(expiresDateMs as! Int))
            }
        }
        return nil
    }
    
    func availableCredits(forConsumable consumableId: String) -> Int {
        return self.purchaseRecord[consumableId] as! Int
    }
    
    func consumeCredits(_ creditCountToConsume: Int, identifiedByConsumableIdentifier consumableId: String) -> Int {
        var currentConsumableCount = self.purchaseRecord[consumableId] as! Int
        currentConsumableCount = currentConsumableCount - creditCountToConsume
        self.purchaseRecord[consumableId] = currentConsumableCount
        self.savePurchaseRecord()
        return currentConsumableCount
    }
    
    func setDefaultCredits(_ creditCount: Int, forConsumableIdentifier consumableId: String) {
        if self.purchaseRecord[consumableId] == nil {
            self.purchaseRecord[consumableId] = creditCount
            self.savePurchaseRecord()
        }
    }
    
    // MARK: -
    // MARK: Start requesting for available in app purchases
    
    func startProductRequest(withProductIdentifiers items: [String]) {
        let productsRequest = SKProductsRequest(productIdentifiers: Set<String>(items))
        productsRequest.delegate = self
        productsRequest.start()
    }
    
    func startProductRequest() {
        var availableConsumables = [String]()
        if let consumables = SteelyStoreKit.configs()["Consumables"] {
            let c = consumables as! [String: Any]
            c.keys.forEach({ consumable in
                availableConsumables.append(consumable)
            })
        }
        print(SteelyStoreKit.configs())
        let others = SteelyStoreKit.configs()["Others"] as! [String]
        self.startProductRequest(withProductIdentifiers: others)
    }
    
    func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        if response.invalidProductIdentifiers.count > 0 {
            print("Invalid Product IDs: \(response.invalidProductIdentifiers)")
        }
        availableProducts = response.products
        NotificationCenter.default.post(name: NSNotification.Name.SteelyStoreKitProductsAvailable, object: self.availableProducts)
    }
    
    func request(_ request: SKRequest, didFailWithError error: Error) {
        print("Product request failed with error: \(error)")
    }
    // MARK: -
    // MARK: Restore Purchases
    
    func restorePurchases() {
        SKPaymentQueue.default().restoreCompletedTransactions()
    }
    
    func paymentQueue(_ queue: SKPaymentQueue, restoreCompletedTransactionsFailedWithError error: Error) {
        NotificationCenter.default.post(name: NSNotification.Name.SteelyStoreKitRestoringPurchasesFailed, object: error)
    }
    
    func paymentQueueRestoreCompletedTransactionsFinished(_ queue: SKPaymentQueue) {
        NotificationCenter.default.post(name: NSNotification.Name.SteelyStoreKitRestoredPurchases, object: nil)
    }
    
    func initiatePaymentRequestForProduct(withIdentifier productId: String) {
        if self.availableProducts == nil {
            // TODO: FIX ME
            // Initializer might be running or internet might not be available
            print("No products are available. Did you initialize SteelyStoreKit by calling [[SteelyStoreKit sharedKit] startProductRequest]?")
            #if TARGET_OS_IPHONE
                var controller = UIAlertController(title: NSLocalizedString("No Products Available", comment: ""), message: NSLocalizedString("Check your parental control settings and try again later", comment: ""), preferredStyle: .alert)
                UIApplication.shared.keyWindow!.rootViewController!.present(controller, animated: true, completion: { _ in })
            #elseif TARGET_OS_MAC
                var noProductsAlert = NSAlert()
                noProductsAlert.messageText = NSLocalizedString("No Products Available", comment: "")
                noProductsAlert.informativeText = NSLocalizedString("Check your parental control settings and try again later", comment: "")
                noProductsAlert.alertStyle = NSInformationalAlertStyle
                noProductsAlert.runModal()
            #endif
            return
        }
        if !SKPaymentQueue.canMakePayments() {
            #if TARGET_OS_IPHONE
                var controller = UIAlertController(title: NSLocalizedString("In App Purchasing Disabled", comment: ""), message: NSLocalizedString("Check your parental control settings and try again later", comment: ""), preferredStyle: .alert)
                UIApplication.shared.keyWindow!.rootViewController!.present(controller, animated: true, completion: { _ in })
            #elseif TARGET_OS_MAC
                var alert = NSAlert()
                alert.messageText = NSLocalizedString("In App Purchasing Disabled", comment: "")
                alert.informativeText = NSLocalizedString("Check your parental control settings and try again later", comment: "")
                alert.alertStyle = NSInformationalAlertStyle
                alert.runModal()
            #endif
            return
        }
        for product in availableProducts! {
            if product.productIdentifier == productId {
                let payment = SKPayment(product: product)
                SKPaymentQueue.default().add(payment)
            }
        }
    }
    
    // MARK: -
    // MARK: Receipt validation
    func refreshAppStoreReceipt() {
        let refreshReceiptRequest = SKReceiptRefreshRequest(receiptProperties: nil)
        refreshReceiptRequest.delegate = self
        refreshReceiptRequest.start()
    }
    
    func requestDidFinish(_ request: SKRequest) {
        // SKReceiptRefreshRequest
        if request is SKReceiptRefreshRequest {
            let receiptUrl = Bundle.main.appStoreReceiptURL!
            if FileManager.default.fileExists(atPath: receiptUrl.path) {
                print("App receipt exists. Preparing to validate and update local stores.")
                self.startValidatingReceiptsAndUpdateLocalStore()
            } else {
                print("Receipt request completed but there is no receipt. The user may have refused to login, or the reciept is missing.")
                // Disable features of your app, but do not terminate the app
            }
        }
    }
    
    func startValidatingAppStoreReceipt(withCompletionHandler completionHandler: @escaping (_ receipts: [[String: Any]]?, _ error: Error?) -> Void) {
        let receiptURL: URL = Bundle.main.appStoreReceiptURL!
        do {
            _ = try receiptURL.checkResourceIsReachable()
        } catch {
            // No receipt - In App Purchase was never initiated
            completionHandler(nil, nil)
            return
        }
        
        do {
            let receiptData = try Data(contentsOf: receiptURL)
            var requestContents = ["receipt-data": receiptData.base64EncodedString(options: Data.Base64EncodingOptions(rawValue: 0))]
            let sharedSecret = SteelyStoreKit.configs()["SharedSecret"] as! String
            if sharedSecret != "" {
                requestContents["password"] = sharedSecret as String?
            }
            let requestData = try! JSONSerialization.data(withJSONObject: requestContents, options: [])
            #if DEBUG
                let storeRequest = NSMutableURLRequest(url: URL(string: kSandboxServer)!)
            #else
                let storeRequest = NSMutableURLRequest(url: URL(string: kLiveServer)!)
            #endif
            storeRequest.httpMethod = "POST"
            storeRequest.httpBody = requestData
            let session = URLSession(configuration: URLSessionConfiguration.default)
            let task = session.dataTask(with: storeRequest as URLRequest) { (data, response, error) -> Void in
                if error == nil {
                    
                    var jsonResponse: [String: Any]
                    do {
                        jsonResponse = try JSONSerialization.jsonObject(with: data!, options: []) as! [String: AnyObject]
                        
                        let status = jsonResponse["status"] as! Int
                        if let _ = jsonResponse["receipt"] {
                            let originalAppVersion = (jsonResponse["receipt"] as! [String: Any])["original_application_version"]
                            if originalAppVersion != nil {
                                self.purchaseRecord[kOriginalAppVersionKey] = originalAppVersion
                                self.savePurchaseRecord()
                            } else {
                                completionHandler(nil, nil)
                            }
                        } else {
                            completionHandler(nil, nil)
                        }
                        if status != 0 {
                            // TODO: Handle error case
                            if let message = self.errorDictionary[status] {
                                let error = SteelyStoreKitError.statusError(domain: "com.pete.steelystorekit", status: status, userInfo: [NSLocalizedDescriptionKey: message])
                                completionHandler(nil, error)
                            }
                        } else {
                            var receipts = jsonResponse["latest_receipt_info"] as! [[String: Any]]
                            if let oldReceipts = jsonResponse["receipt"] {
                                let oR = oldReceipts as! [String: Any]
                                let inAppReceipts: [[String: Any]] = oR["in_app"] as! [[String: Any]]
                                receipts += inAppReceipts
                                completionHandler(receipts, nil)
                            } else {
                                completionHandler(nil, nil)
                            }
                        }
                    } catch {
                        print(error.localizedDescription)
                    }
                } else {
                    completionHandler(nil, error!)
                }
            }
            task.resume()
        } catch {
            print(error.localizedDescription)
            print("Receipt exists but there is no data available. Try refreshing the reciept payload and then checking again.")
            completionHandler(nil, nil)
            return
        }
    }
    
    func purchasedApp(beforeVersion requiredVersion: String) -> Bool {
        let actualVersion = (self.purchaseRecord[kOriginalAppVersionKey] as! String)
        if requiredVersion.compare(actualVersion, options: .numeric) == .orderedDescending {
            // actualVersion is lower than the requiredVersion
            return true
        } else {
            return false
        }
    }
    
    func startValidatingReceiptsAndUpdateLocalStore() {
        self.startValidatingAppStoreReceipt(withCompletionHandler: { (_ receipts: [[String: Any]]?, _ error: Error?) -> Void in
            if error != nil {
                print("Receipt validation failed with error: \(error)")
                NotificationCenter.default.post(name: NSNotification.Name.SteelyStoreKitReceiptValidationFailed, object: error)
            } else {
                var purchaseRecordDirty = false
                if let receipts = receipts {
                    for receiptDictionary in receipts {
                        
                        let productIdentifier = receiptDictionary["product_id"] as! String
                        let expiresDateMs = receiptDictionary["expires_date_ms"] as! Double
                        if expiresDateMs != 0 {
                            // renewable subscription
                            let previouslyStoredExpiresDateMs = self.purchaseRecord[productIdentifier]
                            if !(previouslyStoredExpiresDateMs != nil) || (previouslyStoredExpiresDateMs is NSNull) {
                                self.purchaseRecord[productIdentifier] = expiresDateMs
                                purchaseRecordDirty = true
                            } else {
                                if expiresDateMs > previouslyStoredExpiresDateMs as! Double {
                                    self.purchaseRecord[productIdentifier] = expiresDateMs
                                    purchaseRecordDirty = true
                                }
                            }
                        }
                    }
                }
                if purchaseRecordDirty {
                    self.savePurchaseRecord()
                }
                for (productIdentifier, expiresDateMs) in self.purchaseRecord {
                    if !(expiresDateMs is NSNull) {
                        if Date().timeIntervalSince1970 > expiresDateMs as! Double {
                            NotificationCenter.default.post(name: NSNotification.Name.SteelyStoreKitSubscriptionExpired, object: productIdentifier)
                        }
                    }
                }
            }
        })
    }
    
    private func paymentQueue(_ queue: SKPaymentQueue, updatedDownloads downloads: [Any]) {
        for download in downloads {
            let thisDownload = download as! SKDownload
            var state: SKDownloadState = .paused
            #if os(iOS)
                state = thisDownload.downloadState
            #elseif os(macOS)
                state = thisDownload.state
            #endif
            switch state {
            case .active:
                NotificationCenter.default.post(name: NSNotification.Name.SteelyStoreKitDownloadProgress, object: download, userInfo: [thisDownload.transaction.payment.productIdentifier: (thisDownload.progress)])
            case .finished:
                let documentDirectory = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
                let contentDirectoryForThisProduct = URL(fileURLWithPath: URL(fileURLWithPath: documentDirectory).appendingPathComponent("Contents").absoluteString).appendingPathComponent(thisDownload.transaction.payment.productIdentifier).absoluteString
                do {
                    try FileManager.default.createDirectory(atPath: contentDirectoryForThisProduct, withIntermediateDirectories: true, attributes: nil)
                } catch let error {
                    print(error.localizedDescription)
                }
                do {
                    try FileManager.default.moveItem(at: thisDownload.contentURL!, to: URL(string: contentDirectoryForThisProduct)!)
                } catch let error {
                    print(error.localizedDescription)
                }
                NotificationCenter.default.post(name: NSNotification.Name.SteelyStoreKitDownloadCompleted, object: thisDownload, userInfo: [thisDownload.transaction.transactionIdentifier!: contentDirectoryForThisProduct])
                queue.finishTransaction(thisDownload.transaction)
                
            default:
                break
            }
        }
    }
    
    func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        for transaction: SKPaymentTransaction in transactions {
            switch transaction.transactionState {
            case .purchasing:
                break
            case .deferred:
                self.deferredTransaction(transaction, in: queue)
            case .failed:
                self.failedTransaction(transaction, in: queue)
            case .purchased, .restored:
                if transaction.downloads.count > 0 {
                    SKPaymentQueue.default().start(transaction.downloads)
                } else {
                    queue.finishTransaction(transaction)
                }
                var availableConsumables = SteelyStoreKit.configs()["Consumables"] as! [String: Any]
                let consumables = availableConsumables.keys
                if consumables.contains(transaction.payment.productIdentifier) {
                    var thisConsumable = availableConsumables[transaction.payment.productIdentifier] as! [String: Any]
                    let consumableId = thisConsumable["ConsumableId"] as! String
                    var consumableCount = thisConsumable["ConsumableCount"] as! Double
                    let currentConsumableCount = self.purchaseRecord[consumableId] as! Double
                    consumableCount = consumableCount + currentConsumableCount
                    self.purchaseRecord[consumableId] = consumableCount
                } else {
                    // non-consumable or subscriptions
                    // subscriptions will eventually contain the expiry date after the receipt is validated during the next run
                    self.purchaseRecord[transaction.payment.productIdentifier] = NSNull()
                }
                self.savePurchaseRecord()
                NotificationCenter.default.post(name: NSNotification.Name.SteelyStoreKitProductPurchased, object: transaction.payment.productIdentifier)
                
            }
        }
    }
    
    func failedTransaction(_ transaction: SKPaymentTransaction, in queue: SKPaymentQueue) {
        print("Transaction Failed with error: \(transaction.error)")
        queue.finishTransaction(transaction)
        NotificationCenter.default.post(name: NSNotification.Name.SteelyStoreKitProductPurchaseFailed, object: transaction.payment.productIdentifier)
    }
    
    func deferredTransaction(_ transaction: SKPaymentTransaction, in queue: SKPaymentQueue) {
        print("Transaction Deferred: \(transaction)")
        NotificationCenter.default.post(name: NSNotification.Name.SteelyStoreKitProductPurchaseDeferred, object: transaction.payment.productIdentifier)
    }
}

