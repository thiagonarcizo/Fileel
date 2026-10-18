import CoreML
import Vision

// keep hardware acceleration on real macs and retry on supported CPU stages when it is unavailable
enum VisionExecution {
    static func perform(_ requests: [VNRequest], handler: VNImageRequestHandler, preferCPU: Bool = false) throws {
        if preferCPU {
            try useCPU(requests)
            try handler.perform(requests)
            return
        }
        do { try handler.perform(requests) }
        catch {
            try Task.checkCancellation()
            try useCPU(requests)
            try handler.perform(requests)
        }
    }

    private static func useCPU(_ requests: [VNRequest]) throws {
        for request in requests {
            for (stage, devices) in try request.supportedComputeStageDevices {
                if let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) {
                    request.setComputeDevice(cpu, for: stage)
                }
            }
        }
    }
}
