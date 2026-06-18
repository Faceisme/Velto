import CoreGraphics

/// Pixelates a rectangular region of the immutable base image. The renderer only
/// reads from `baseImage`, never from the in-progress context, so vector objects
/// drawn afterwards are never sampled into the mosaic.
public enum AnnotationMosaicRenderer {
  public static func draw(
    _ mosaic: MosaicAnnotation,
    baseImage: CGImage,
    scale: CGFloat,
    in context: CGContext
  ) {
    let rect = mosaic.rect.standardized
    guard rect.width > 0, rect.height > 0, scale > 0 else { return }

    // Base image pixels live in a top-left origin space, matching annotation
    // coordinates, so the region maps straight through `rect * scale`.
    let imageBounds = CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height)
    let pixelRegion = CGRect(
      x: (rect.minX * scale).rounded(.down),
      y: (rect.minY * scale).rounded(.down),
      width: (rect.width * scale).rounded(.up),
      height: (rect.height * scale).rounded(.up)
    ).intersection(imageBounds)
    guard !pixelRegion.isNull, pixelRegion.width >= 1, pixelRegion.height >= 1 else { return }
    guard let region = baseImage.cropping(to: pixelRegion) else { return }

    let blockPixels = max(1, Int((CGFloat(mosaic.blockSize) * scale).rounded()))
    let smallWidth = max(1, region.width / blockPixels)
    let smallHeight = max(1, region.height / blockPixels)

    guard let downsampleContext = CGContext(
      data: nil,
      width: smallWidth,
      height: smallHeight,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }

    // Averaging downsample, then a nearest-neighbour upscale gives blocky pixels.
    downsampleContext.interpolationQuality = .medium
    downsampleContext.draw(
      region,
      in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight)
    )
    guard let blockImage = downsampleContext.makeImage() else { return }

    context.saveGState()
    context.interpolationQuality = .none
    // Map the mosaic back to the exact pixels it covered, so a region clamped at
    // the image edge is not stretched across the whole annotation rect.
    let drawRect = CGRect(
      x: pixelRegion.minX / scale,
      y: pixelRegion.minY / scale,
      width: pixelRegion.width / scale,
      height: pixelRegion.height / scale
    )
    context.draw(blockImage, in: drawRect)
    context.restoreGState()
  }
}
