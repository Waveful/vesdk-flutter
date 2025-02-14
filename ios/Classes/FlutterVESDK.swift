import Flutter
import UIKit
import ImglyKit
import imgly_sdk
import AVFoundation

// Helper extension for replacing default icons with custom icons.
// Source: https://img.ly/docs/vesdk/ios/guides/user-interface/customize-icons/
private extension UIImage {
    /// Create a new icon image for a specific size by centering the input image and optionally applying alpha blending.
    /// - Parameters:
    ///   - pt: Icon size in point (pt).
    ///   - alpha: Icon alpha value.
    /// - Returns: A new icon image.
    func icon(pt: CGFloat, alpha: CGFloat = 1) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(CGSize(width: pt, height: pt), false, scale)
        let position = CGPoint(x: (pt - size.width) / 2, y: (pt - size.height) / 2)
        draw(at: position, blendMode: .normal, alpha: alpha)
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return newImage
    }
}

@available(iOS 13.0, *)
public class FlutterVESDK: FlutterIMGLY, FlutterPlugin, VideoEditViewControllerDelegate {

    // MARK: - Typealias

    /// A closure to modify a new `VideoEditViewController` before it is presented on screen.
    public typealias VESDKWillPresentBlock = (_ videoEditViewController: VideoEditViewController) -> Void

    // MARK: - Properties

    /// Set this closure to modify a new `VideoEditViewController` before it is presented on screen.
    public static var willPresentVideoEditViewController: VESDKWillPresentBlock?

    /// The `UUID` of the current editor instance.
    private var uuid: UUID?

    // MARK: - Flutter Channel

    /// Registers for the channel in order to communicate with the
    /// Flutter plugin.
    /// - Parameter registrar: The `FlutterPluginRegistrar` used to register.
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "video_editor_sdk", binaryMessenger: registrar.messenger())
        let instance = FlutterVESDK()
        registrar.addMethodCallDelegate(instance, channel: channel)
        FlutterVESDK.registrar = registrar
        FlutterVESDK.methodeChannel = channel
    }

    /// Retrieves the methods and initiates the fitting behavior.
    /// - Parameter call: The `FlutterMethodCall` containig the information about the method.
    /// - Parameter result: The `FlutterResult` to return to the Flutter plugin.
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let arguments = call.arguments as? IMGLYDictionary else { return }

        if self.result != nil {
            result(FlutterError(code: IMGLYConstants.kErrorMultipleRequests, message: "Cancelled due to multiple requests.", details: nil))
            return
        }

        if call.method == "openEditor" {
            self.openEditor(arguments: arguments, result: result)
        } else if call.method == "unlock" {
            guard let license = arguments["license"] as? String else { return }
            self.result = result
            self.unlockWithLicense(with: license)
        } else if call.method == "release" {
            result(nil)
        } else {
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Presenting editor

    /// Presents the video editor if available.
    ///
    /// - Parameter arguments: The arguments from the method channel request.
    /// - Parameter result: The `FlutterResult` used to communicate with the Dart layer.
    private func openEditor(arguments: IMGLYDictionary, result: @escaping FlutterResult) {
        let configuration = arguments["configuration"] as? IMGLYDictionary
        let serialization = arguments["serialization"] as? IMGLYDictionary
        let videoDictionary = arguments["video"] as? IMGLYDictionary

        if videoDictionary != nil {
            self.result = result
            let (size, valid) = convertSize(from: videoDictionary?["size"] as? IMGLYDictionary)
            var video: Video?

            if let videos = videoDictionary?["videos"] as? [String] {
                let resolvedAssets = videos.compactMap { EmbeddedAsset(from: $0).resolvedURL }
                let assets = resolvedAssets.compactMap{ URL(string: $0) }.map{ VideoSegment(url: $0) }

                if assets.count > 0 {
                    if let videoSize = size {
                        video = Video(segments: assets, size: videoSize)
                    } else {
                        if valid == true {
                            video = Video(segments: assets)
                        } else {
                            result(FlutterError(code: IMGLYConstants.kErrorUnableToLoad, message: "Invalid video size: width and height must be greater than zero.", details: nil))
                            return
                        }
                    }
                } else {
                    if let videoSize = size {
                        video = Video(size: videoSize)
                    } else {
                        result(FlutterError(code: IMGLYConstants.kErrorUnableToLoad, message: "A video composition without assets must have a specific size.", details: nil))
                        return
                    }
                }
            } else if let segments = videoDictionary?["segments"] as? [IMGLYDictionary] {
                var resolvedSegments: [VideoSegment] = []
                segments.forEach { segment in
                    guard let videoURI = segment["videoUri"] as? String, let resolvedURI = EmbeddedAsset(from: videoURI).resolvedURL, let resolvedURL = URL(string: resolvedURI) else { return }
                    let startTime = segment["startTime"] as? Double
                    let endTime = segment["endTime"] as? Double
                    let resolvedSegment = VideoSegment(url: resolvedURL, startTime: startTime, endTime: endTime)
                    resolvedSegments.append(resolvedSegment)
                }

                if resolvedSegments.count > 0 {
                    if let videoSize = size {
                        video = Video(segments: resolvedSegments, size: videoSize)
                    } else {
                        if valid == true {
                            video = Video(segments: resolvedSegments)
                        } else {
                            result(FlutterError(code: IMGLYConstants.kErrorUnableToLoad, message: "Invalid video size: width and height must be greater than zero.", details: nil))
                            return
                        }
                    }
                } else {
                    if let videoSize = size {
                        video = Video(size: videoSize)
                    } else {
                        result(FlutterError(code: IMGLYConstants.kErrorUnableToLoad, message: "A video composition without assets must have a specific size.", details: nil))
                        return
                    }
                }

            } else if let source = videoDictionary?["video"] as? String {
                if let resolvedSource = EmbeddedAsset(from: source).resolvedURL, let url = URL(string: resolvedSource) {
                    video = Video(segment: VideoSegment(url: url))
                }
            } else if let videoSize = size {
                video = Video(size: videoSize)
            }
            guard let finalVideo = video else {
                result(FlutterError(code: IMGLYConstants.kErrorUnableToLoad, message: "Could not load video.", details: nil))
                return
            }

            self.present(video: finalVideo, configuration: configuration, serialization: serialization)
        } else {
            result(FlutterError(code: IMGLYConstants.kErrorUnableToLoad, message: "The video must not be null.", details: nil))
            return
        }
    }

    /// Presents an instance of `VideoEditViewController`.
    /// - Parameter video: The `Video` to initialize the editor with.
    /// - Parameter configuration: The configuration for the editor in JSON format.
    /// - Parameter serialization: The serialization as `IMGLYDictionary`.
    private func present(video: Video, configuration: IMGLYDictionary?, serialization: IMGLYDictionary?) {
        self.uuid = UUID()
        self.present(mediaEditViewControllerBlock: { (configurationData, serializationData) -> MediaEditViewController? in

            // Customize icons.
            // Source: https://img.ly/docs/vesdk/ios/guides/user-interface/customize-icons/

            // This example replaces some of the default icons with symbol images provided by SF Symbols.
            // Create a symbol configuration with scale variant large as the default is too small for our use case.
            let config = UIImage.SymbolConfiguration(scale: .large)

            // Set up the image replacement closure (once) before the editor is initialized.
            IMGLY.bundleImageBlock = { imageName in
                // Return replacement images for the requested image name.
                // Most icon image names use the `pt` postfix which states the expected dimensions for the used image measured
                // in points (pt), e.g., the postfix `_48pt` stands for an image of 48x48 pixels for scale factor 1.0 and 96x96
                // pixels (@2x) as well as 144x144 pixels (@3x) for its high-resolution variants.
                switch imageName {
                    case "imgly_icon_save":
                        return UIImage(systemName: "chevron.forward", withConfiguration: config)?.icon(pt: 44, alpha: 0.6)

                    // Returning `nil` will use the default icon image.
                    default:
                        return nil
                }
            }


            var photoEditModel = PhotoEditModel()
            var videoEditViewController: VideoEditViewController

            if let _serialization = serializationData {
                let deserializationResult = Deserializer.deserialize(data: _serialization, imageDimensions: video.size, assetCatalog: configurationData?.assetCatalog ?? .defaultItems)
                photoEditModel = deserializationResult.model ?? photoEditModel
            }

            if let configuration = configurationData {
                videoEditViewController = VideoEditViewController.makeVideoEditViewController(videoAsset: video, configuration: configuration, photoEditModel: photoEditModel)
            } else {
                videoEditViewController = VideoEditViewController.makeVideoEditViewController(videoAsset: video, photoEditModel: photoEditModel)
            }
            videoEditViewController.modalPresentationStyle = .fullScreen
            videoEditViewController.delegate = self

            FlutterVESDK.willPresentVideoEditViewController?(videoEditViewController)

            return videoEditViewController
        }, utiBlock: { (configurationData) -> CFString in
            return (configurationData?.videoEditViewControllerOptions.videoContainerFormatUTI ?? AVFileType.mp4 as CFString)
        }, configurationData: configuration, serialization: serialization)
    }

    // MARK: - Licensing

    /// Unlocks the license from a url.
    /// - Parameter url: The URL where the license file is located.
    public override func unlockWithLicenseFile(at url: URL) {
        DispatchQueue.main.async {
            do {
                try VESDK.unlockWithLicense(from: url)
                self.result?(nil)
                self.result = nil
            } catch let error {
                self.result?(FlutterError(code: IMGLYConstants.kErrorUnableToUnlock, message: "Unlocking the SDK failed due to:", details: error.localizedDescription))
                self.result = nil
            }
        }
    }

    // MARK: - Helpers

    /// Converts a given dictionary into a `CGSize`.
    /// - Parameter dictionary: The `IMGLYDictionary` to retrieve the size from.
    /// - Returns: The converted `CGSize` if any and a `bool` indicating whether size is valid.
    private func convertSize(from dictionary: IMGLYDictionary?) -> (CGSize?, Bool) {
        if let validDictionary = dictionary {
            guard let height = validDictionary["height"] as? Double, let width = validDictionary["width"] as? Double else {
                return (nil, false)
            }
            if height > 0 && width > 0 {
                return (CGSize(width: width, height: height), true)
            }
            return (nil, false)
        } else {
            return (nil, true)
        }
    }

    /// Handles an occuring error and closes the editor.
    /// - Parameter videoEditViewController: The `VideoEditViewController` that caused the error.
    /// - Parameter code: The error code.
    /// - Parameter message: The error message.
    /// - Parameter details: The error details.
    private func handleError(_ videoEditViewController: VideoEditViewController, code: String, message: String?, details: Any?) {
        self.dismiss(mediaEditViewController: videoEditViewController, animated: true) {
            self.result?(FlutterError(code: code, message: message, details: details))
            self.result = nil
            self.uuid = nil
        }
    }

    /// Serializes the given video segments.
    ///
    /// - Parameter segments: The `VideoSegment`s to serialize.
    /// - Returns: The serialized segments as `IMGLYDictionary`.
    private func serializeSegments(segments: [VideoSegment]) -> [IMGLYDictionary] {
        return segments.compactMap { segment in
            var result: IMGLYDictionary = ["videoUri": segment.url.absoluteString]

            if (segment.startTime != nil) {
                result["startTime"] = segment.startTime
            }
            if (segment.endTime != nil) {
                result["endTime"] = segment.endTime
            }
            return result
        }
    }
}

@available(iOS 13.0, *)
extension FlutterVESDK {
    /// Called if the video has been successfully exported.
    /// - Parameter videoEditViewController: The instance of `VideoEditViewController` that finished exporting
    /// - Parameter result: The `VideoEditorResult` from the editor.
    public func videoEditViewControllerDidFinish(_ videoEditViewController: VideoEditViewController, result: VideoEditorResult) {
        var serialization: Any?

        if self.serializationEnabled == true {
            guard let serializationData = videoEditViewController.serializedSettings else {
                self.handleError(videoEditViewController, code: IMGLYConstants.kErrorUnableToExport, message: "No serialization data found.", details: nil)
                return
            }
            if self.serializationType == IMGLYConstants.kExportTypeFileURL {
                guard let exportURL = self.serializationFile else {
                    self.handleError(videoEditViewController, code: IMGLYConstants.kErrorUnableToExport, message: "The URL must not be nil.", details: nil)
                    return
                }
                do {
                    try serializationData.IMGLYwriteToUrl(exportURL, andCreateDirectoryIfNeeded: true)
                    serialization = self.serializationFile?.absoluteString
                } catch let error {
                  self.handleError(videoEditViewController, code: IMGLYConstants.kErrorUnableToExport, message: error.localizedDescription, details: error.localizedDescription)
                    return
                }
            } else if self.serializationType == IMGLYConstants.kExportTypeObject {
                do {
                    serialization = try JSONSerialization.jsonObject(with: serializationData, options: .init(rawValue: 0))
                } catch let error {
                  self.handleError(videoEditViewController, code: IMGLYConstants.kErrorUnableToExport, message: error.localizedDescription, details: error.localizedDescription)
                    return
                }
            }
        }

        self.dismiss(mediaEditViewController: videoEditViewController, animated: true) {
            let serializedSegments = self.serializeSegments(segments: result.task.video.segments)
            var res: [String: Any?] = ["video": result.output.url.absoluteString, "hasChanges": result.status == .renderedWithChanges, "serialization": serialization, "videoSize": ["height": result.task.video.size.height, "width": result.task.video.size.width], "identifier": self.uuid?.uuidString]
            if self.serializeVideoSegments {
                res["segments"] = serializedSegments
            }
            self.result?(res)
            self.result = nil
            self.uuid = nil
        }
    }

    /// Called if the `VideoEditViewController` failed to export the video.
    /// - Parameter videoEditViewController: The `VideoEditViewController` that failed to export the video.
    /// - Parameter error: The `VideoEditorError` that caused the failure.
    public func videoEditViewControllerDidFail(_ videoEditViewController: VideoEditViewController, error: VideoEditorError) {
      self.handleError(videoEditViewController, code: IMGLYConstants.kErrorUnableToExport, message: "The editor did fail to generate the video.", details: error.localizedDescription)
    }

    /// Called if the `VideoEditViewController` was cancelled.
    /// - Parameter videoEditViewController: The `VideoEditViewController` that has been cancelled.
    public func videoEditViewControllerDidCancel(_ videoEditViewController: VideoEditViewController) {
        self.dismiss(mediaEditViewController: videoEditViewController, animated: true) {
            self.result?(nil)
            self.result = nil
            self.uuid = nil
        }
    }
}
