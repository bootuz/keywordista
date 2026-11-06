import AppleAdsClient

/// The generated Apple Ads API client. Why an alias: Vapor also exports a
/// `Client`, and `AppleAdsClient.Client` resolves to the library's struct of
/// the same name as its module rather than the module, so the generated type
/// is only nameable from a file that doesn't import Vapor — this one.
typealias AppleAdsAPI = Client
