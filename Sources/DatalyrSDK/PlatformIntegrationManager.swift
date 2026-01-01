import Foundation

// MARK: - Storage Keys

internal enum PlatformStorageKeys {
    static let deferredAttributionFetched = "deferred_attribution_fetched"
    static let deferredAttributionData = "deferred_attribution_data"
}

// MARK: - Platform Integration Manager

/// Manages platform SDK integrations (Meta, TikTok, Apple Search Ads)
internal class PlatformIntegrationManager {
    private var metaIntegration: MetaIntegration?
    private var tiktokIntegration: TikTokIntegration?
    private var asaIntegration: AppleSearchAdsIntegration?
    private var deferredAttributionData: DeferredDeepLinkResult?
    private let storage = DatalyrStorage.shared

    /// Initialize platform integrations based on configuration
    func initialize(config: DatalyrConfig) async {
        // Initialize Meta SDK if App ID is provided
        if let metaAppId = config.metaAppId, !metaAppId.isEmpty {
            metaIntegration = MetaIntegration(
                appId: metaAppId,
                clientToken: config.metaClientToken,
                enableAttribution: config.enableMetaAttribution,
                forwardEvents: config.forwardEventsToMeta,
                debug: config.debug
            )
            await metaIntegration?.initialize()
        }

        // Initialize TikTok SDK if App ID is provided
        if let tiktokAppId = config.tiktokAppId, !tiktokAppId.isEmpty {
            // Use eventsAppId if provided, otherwise fall back to tiktokAppId for backward compatibility
            let eventsAppId = config.tiktokEventsAppId ?? tiktokAppId
            tiktokIntegration = TikTokIntegration(
                eventsAppId: eventsAppId,
                tiktokAppId: tiktokAppId,
                accessToken: config.tiktokAccessToken,
                enableAttribution: config.enableTikTokAttribution,
                forwardEvents: config.forwardEventsToTikTok,
                debug: config.debug
            )
            await tiktokIntegration?.initialize()
        }

        // Initialize Apple Search Ads (always, if attribution enabled)
        if config.enableAttribution {
            asaIntegration = AppleSearchAdsIntegration()
            await asaIntegration?.initialize(debug: config.debug)
        }

        debugLog("Platform integrations initialized", data: [
            "meta_enabled": metaIntegration != nil,
            "tiktok_enabled": tiktokIntegration != nil,
            "asa_enabled": asaIntegration?.isAvailable() ?? false
        ])
    }

    /// Fetch deferred deep links from all platforms
    /// Should be called on first app launch only
    func fetchDeferredAttribution() async -> DeferredDeepLinkResult? {
        // Check if we've already fetched attribution
        let hasFetched = await storage.getBool(PlatformStorageKeys.deferredAttributionFetched)
        if hasFetched == true {
            debugLog("Deferred attribution already fetched, returning cached data")
            return await loadCachedDeferredAttribution()
        }

        // Fetch from Meta first (has better deferred deep link support)
        if let metaResult = await metaIntegration?.fetchDeferredAppLink() {
            debugLog("Got deferred attribution from Meta")
            deferredAttributionData = metaResult
            await saveDeferredAttribution(metaResult)
            await storage.setBool(PlatformStorageKeys.deferredAttributionFetched, value: true)
            return metaResult
        }

        // Try TikTok (limited deferred deep link support)
        if let tiktokResult = tiktokIntegration?.getAttributionData() {
            debugLog("Got attribution data from TikTok")
            deferredAttributionData = tiktokResult
            await saveDeferredAttribution(tiktokResult)
            await storage.setBool(PlatformStorageKeys.deferredAttributionFetched, value: true)
            return tiktokResult
        }

        // Mark as fetched even if no data found
        await storage.setBool(PlatformStorageKeys.deferredAttributionFetched, value: true)

        return nil
    }

    /// Forward purchase event to all platforms
    func forwardPurchase(value: Double, currency: String, productId: String?, parameters: [String: Any]?) {
        metaIntegration?.logPurchase(value: value, currency: currency, parameters: parameters)
        tiktokIntegration?.logPurchase(value: value, currency: currency, contentId: productId, contentType: "product", parameters: parameters)
    }

    /// Forward subscription event to all platforms
    func forwardSubscription(value: Double, currency: String, plan: String?) {
        var metaParams: [String: Any] = [:]
        if let plan = plan {
            metaParams["subscription_plan"] = plan
        }
        metaIntegration?.logEvent(name: "Subscribe", parameters: metaParams, valueToSum: value)
        tiktokIntegration?.logSubscription(value: value, currency: currency, plan: plan)
    }

    /// Forward custom event to all platforms
    func forwardEvent(name: String, parameters: [String: Any]?, valueToSum: Double?) {
        metaIntegration?.logEvent(name: name, parameters: parameters, valueToSum: valueToSum)
        tiktokIntegration?.logEvent(name: name, properties: parameters)
    }

    /// Forward add to cart event
    func forwardAddToCart(value: Double, currency: String, productId: String?, productName: String?) {
        var metaParams: [String: Any] = ["currency": currency]
        if let productId = productId { metaParams["content_ids"] = [productId] }
        if let productName = productName { metaParams["content_name"] = productName }

        metaIntegration?.logEvent(name: "AddToCart", parameters: metaParams, valueToSum: value)
        tiktokIntegration?.logAddToCart(value: value, currency: currency, contentId: productId, contentType: "product")
    }

    /// Forward view content/product event
    func forwardViewContent(contentId: String?, contentName: String?, contentType: String?, value: Double?, currency: String?) {
        var metaParams: [String: Any] = [:]
        if let contentId = contentId { metaParams["content_ids"] = [contentId] }
        if let contentName = contentName { metaParams["content_name"] = contentName }
        if let contentType = contentType { metaParams["content_type"] = contentType }
        if let currency = currency { metaParams["currency"] = currency }

        metaIntegration?.logEvent(name: "ViewContent", parameters: metaParams, valueToSum: value)
        tiktokIntegration?.logViewContent(
            contentId: contentId,
            contentName: contentName,
            contentType: contentType ?? "product",
            value: value,
            currency: currency
        )
    }

    /// Forward initiate checkout event
    func forwardInitiateCheckout(value: Double, currency: String, numItems: Int?, contentIds: [String]?) {
        var metaParams: [String: Any] = ["currency": currency, "num_items": numItems ?? 1]
        if let contentIds = contentIds { metaParams["content_ids"] = contentIds }

        metaIntegration?.logEvent(name: "InitiateCheckout", parameters: metaParams, valueToSum: value)
        tiktokIntegration?.logInitiateCheckout(
            value: value,
            currency: currency,
            numItems: numItems,
            contentIds: contentIds
        )
    }

    /// Forward complete registration event
    func forwardCompleteRegistration(method: String?) {
        var metaParams: [String: Any] = [:]
        if let method = method { metaParams["registration_method"] = method }

        metaIntegration?.logEvent(name: "CompleteRegistration", parameters: metaParams)
        tiktokIntegration?.logCompleteRegistration(method: method)
    }

    /// Forward search event
    func forwardSearch(query: String, contentIds: [String]?) {
        var metaParams: [String: Any] = ["search_string": query]
        if let contentIds = contentIds { metaParams["content_ids"] = contentIds }

        metaIntegration?.logEvent(name: "Search", parameters: metaParams)
        tiktokIntegration?.logSearch(query: query, contentIds: contentIds)
    }

    /// Forward lead/contact event
    func forwardLead(value: Double?, currency: String?) {
        var metaParams: [String: Any] = [:]
        if let currency = currency { metaParams["currency"] = currency }

        metaIntegration?.logEvent(name: "Lead", parameters: metaParams, valueToSum: value)
        tiktokIntegration?.logLead(value: value, currency: currency)
    }

    /// Forward add payment info event
    func forwardAddPaymentInfo(success: Bool) {
        metaIntegration?.logEvent(name: "AddPaymentInfo", parameters: ["success": success ? 1 : 0])
        tiktokIntegration?.logAddPaymentInfo(success: success)
    }

    /// Identify user on all platforms with full user data for Advanced Matching
    func identifyUser(
        userId: String?,
        email: String?,
        phone: String?,
        firstName: String? = nil,
        lastName: String? = nil,
        dateOfBirth: String? = nil,
        gender: String? = nil,
        city: String? = nil,
        state: String? = nil,
        zip: String? = nil,
        country: String? = nil
    ) {
        // TikTok identification
        tiktokIntegration?.identify(email: email, phone: phone, externalId: userId)

        // Meta Advanced Matching - set all available user data
        metaIntegration?.setUserData(
            email: email,
            firstName: firstName,
            lastName: lastName,
            phone: phone,
            dateOfBirth: dateOfBirth,
            gender: gender,
            city: city,
            state: state,
            zip: zip,
            country: country
        )
    }

    /// Clear user data on all platforms (call on logout/reset)
    func clearUserData() {
        metaIntegration?.clearUserData()
        tiktokIntegration?.logout()
    }

    /// Update tracking authorization on all platforms after ATT prompt
    /// Call this after the user responds to the ATT permission dialog
    func updateTrackingAuthorization() {
        metaIntegration?.updateTrackingAuthorization()
        tiktokIntegration?.updateTrackingAuthorization()
    }

    /// Check if tracking is authorized (ATT)
    func isTrackingAuthorized() -> Bool {
        return metaIntegration?.isTrackingAuthorized() ?? true
    }

    /// Get ATT authorization status
    /// Returns: 0 = notDetermined, 1 = restricted, 2 = denied, 3 = authorized
    func getTrackingAuthorizationStatus() -> UInt {
        return metaIntegration?.getTrackingAuthorizationStatus() ?? 3
    }

    /// Get cached deferred attribution data
    func getDeferredAttributionData() -> DeferredDeepLinkResult? {
        return deferredAttributionData
    }

    /// Check if Meta integration is available
    func isMetaAvailable() -> Bool {
        return metaIntegration?.isAvailable() ?? false
    }

    /// Check if TikTok integration is available
    func isTikTokAvailable() -> Bool {
        return tiktokIntegration?.isAvailable() ?? false
    }

    /// Check if Apple Search Ads integration is available
    func isAppleSearchAdsAvailable() -> Bool {
        return asaIntegration?.isAvailable() ?? false
    }

    /// Get Apple Search Ads attribution data
    func getAppleSearchAdsAttribution() -> AppleSearchAdsAttribution? {
        return asaIntegration?.getAttributionData()
    }

    /// Get Apple Search Ads attribution as dictionary for event payloads
    func getAppleSearchAdsData() -> [String: Any]? {
        return asaIntegration?.toDictionary()
    }

    // MARK: - Private Methods

    private func saveDeferredAttribution(_ data: DeferredDeepLinkResult) async {
        // Convert to dictionary for storage
        var dict: [String: String] = [:]
        if let url = data.url { dict["url"] = url }
        if let source = data.source { dict["source"] = source }
        if let fbclid = data.fbclid { dict["fbclid"] = fbclid }
        if let ttclid = data.ttclid { dict["ttclid"] = ttclid }
        if let utmSource = data.utmSource { dict["utm_source"] = utmSource }
        if let utmMedium = data.utmMedium { dict["utm_medium"] = utmMedium }
        if let utmCampaign = data.utmCampaign { dict["utm_campaign"] = utmCampaign }
        if let utmContent = data.utmContent { dict["utm_content"] = utmContent }
        if let utmTerm = data.utmTerm { dict["utm_term"] = utmTerm }
        if let campaignId = data.campaignId { dict["campaign_id"] = campaignId }
        if let adsetId = data.adsetId { dict["adset_id"] = adsetId }
        if let adId = data.adId { dict["ad_id"] = adId }

        await storage.setCodable(PlatformStorageKeys.deferredAttributionData, value: dict)
    }

    private func loadCachedDeferredAttribution() async -> DeferredDeepLinkResult? {
        guard let dict: [String: String] = await storage.getCodable(PlatformStorageKeys.deferredAttributionData, type: [String: String].self) else {
            return nil
        }

        var result = DeferredDeepLinkResult()
        result.url = dict["url"]
        result.source = dict["source"]
        result.fbclid = dict["fbclid"]
        result.ttclid = dict["ttclid"]
        result.utmSource = dict["utm_source"]
        result.utmMedium = dict["utm_medium"]
        result.utmCampaign = dict["utm_campaign"]
        result.utmContent = dict["utm_content"]
        result.utmTerm = dict["utm_term"]
        result.campaignId = dict["campaign_id"]
        result.adsetId = dict["adset_id"]
        result.adId = dict["ad_id"]

        deferredAttributionData = result
        return result
    }
}
