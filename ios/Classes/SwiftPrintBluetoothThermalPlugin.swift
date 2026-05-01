import Flutter
import UIKit
import CoreBluetooth

public class SwiftPrintBluetoothThermalPlugin: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate,  FlutterPlugin {
    var centralManager: CBCentralManager?  // Define una variable para guardar el gestor central de bluetooth
    var discoveredDevices: [String] = []  //lista de bluetooths encontrados
    var connectedPeripheral: CBPeripheral?  //dispositivo conectado
    var targetService: CBService? // Variable global para el servicio objetivo
    //var characteristics: [CBCharacteristic] = [] // Variable global para almacenar las características encontradas
    var targetCharacteristic: CBCharacteristic? // Variable global para almacenar la característica objetivo


    var flutterResult: FlutterResult? //para el resul de flutter
    var bytes: [UInt8]? //variable para almacenar los bytes que llegan
    var stringprint = ""; //variable para almacenar los string que llegan

    // Flow-control state for chunked writes.
    // writeReadySemaphore is signaled by peripheralIsReadyToSendWriteWithoutResponse
    // when the BLE outbound queue has room for the next chunk.
    let writeReadySemaphore = DispatchSemaphore(value: 0)
    var writeQueueIsBlocked = false

    // En el método init, inicializa el gestor central con un delegado
    //para solicitar el permiso del bluetooth
    override init() {
        super.init()
    }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "groons.web.app/print", binaryMessenger: registrar.messenger())
    let instance = SwiftPrintBluetoothThermalPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    // En el método init, inicializa el gestor central con un delegado
    //para solicitar el permiso del bluetooth
    if (self.centralManager == nil) {
        self.centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    //para iniciar la variable result
    self.flutterResult = result
    //result("iOS " + UIDevice.current.systemVersion)
    //let argumento = call.arguments as! String //leer el argumento recibido
    if call.method == "getPlatformVersion" { // Verifica si se está llamando el método "getPlatformVersion"
      let iosVersion = UIDevice.current.systemVersion // Obtiene la versión de iOS
      result("iOS " + iosVersion) // Devuelve el resultado como una cadena de texto
    } else if call.method == "getBatteryLevel" {
      let device = UIDevice.current
      let batteryState = device.batteryState
      let batteryLevel = device.batteryLevel * 100
      result(Int(batteryLevel))
    } else if call.method == "bluetoothenabled"{
      switch centralManager?.state {
      case .poweredOn:
          result(true)
      default:
          result(false)
      }
    } else if call.method == "ispermissionbluetoothgranted"{
      //let centralManager = CBCentralManager()
      if #available(iOS 10.0, *) {
        switch centralManager?.state {
        case .poweredOn:
          print("Bluetooth is on")
          result(true)
        default:
          print("Bluetooth is off")
          result(false)
        }
      }
    } else if call.method == "pairedbluetooths" {
      //print("buscando bluetooths");
      //let discoveredDevices = scanForBluetoothDevices(duration: 5.0)
      //print("Discovered devices: \(discoveredDevices)")
      switch centralManager?.state {
        case .unknown:
            //print("El estado del bluetooth es desconocido")
            break
        case .resetting:
            //print("El bluetooth se está reiniciando")
            break
        case .unsupported:
            //print("El bluetooth no es compatible con este dispositivo")
            break
        case .unauthorized:
            //print("El bluetooth no está autorizado para esta app")
            break
        case .poweredOff:
            //print("El bluetooth está apagado")
            centralManager?.stopScan()
        case .poweredOn:
            //print("El bluetooth está encendido")
            //Escanea todos los bluetooths disponibles
            centralManager?.scanForPeripherals(withServices: nil, options: nil)
            // Escanea todos los dispositivos Bluetooth vinculados
            centralManager?.retrieveConnectedPeripherals(withServices: [])
        @unknown default:
            //print("El estado del bluetooth es desconocido (default)")
            break
      }

        // despues de 5 segundos se para la busqueda y se devuelve la lista de dispositivos disponibles
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            self.centralManager?.stopScan()
            print("Stopped scanning -> Discovered devices: \(self.discoveredDevices.count)")
            result(self.discoveredDevices)
        }

    } 
    else if call.method == "connect"{
        guard let macAddress = call.arguments as? String,
              let uuid = UUID(uuidString: macAddress) else {
          result(false)
          return
        }
        // Busca el dispositivo con la dirección MAC dada
        let peripherals = centralManager?.retrievePeripherals(withIdentifiers: [uuid])
        guard let peripheral = peripherals?.first else {
          //print("No se encontró ningún dispositivo con la dirección MAC \(macAddress)")
          result(false)
          return
        }

        // Intenta conectar con el dispositivo
        centralManager?.connect(peripheral, options: nil)

        // Verifica si la conexión fue exitosa después de un tiempo de espera
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if peripheral.state == .connected {
                //print("Conexión exitosa con el dispositivo \(peripheral.name ?? "Desconocido")")
                self.connectedPeripheral = peripheral

                self.connectedPeripheral?.delegate = self
                // Discover services of the connected peripheral
                //se ejecuta los servicios descubiertos en primer peripheral
                self.connectedPeripheral?.discoverServices(nil)
                result(true)
            } else {
                //print("La conexión con el dispositivo \(peripheral.name ?? "Desconocido") falló")
                result(false)
            }
        }
  
    }else if call.method == "connectionstatus"{
      if connectedPeripheral?.state == CBPeripheralState.connected {
          //print("El dispositivo periférico está conectado.")
          result(true)
      } else {
          //print("El dispositivo periférico no está conectado.")
          result(false)
      }
    }else if call.method == "writebytes"{
        // Accept either:
        //  - FlutterStandardTypedData (Uint8List from Dart — used by writeBytesRaw)
        //  - [Int] / [UInt8] (legacy List<int> path used by writeBytes)
        var data: Data
        if let typed = call.arguments as? FlutterStandardTypedData {
            data = typed.data
        } else if let intArr = call.arguments as? [Int] {
            data = Data(intArr.map { UInt8(truncatingIfNeeded: $0) })
        } else if let byteArr = call.arguments as? [UInt8] {
            data = Data(byteArr)
        } else {
            print("writebytes: invalid arguments type: \(type(of: call.arguments))")
            result(false)
            return
        }

        guard let characteristic = targetCharacteristic, let peripheral = self.connectedPeripheral else {
            print("writebytes: no target characteristic / peripheral")
            result(false)
            return
        }

        // Use writeWithoutResponse with proper flow control via
        // peripheralIsReadyToSendWriteWithoutResponse. This is iOS's
        // documented high-throughput pattern — writeValue with .withResponse
        // requires waiting for didWriteValueFor between EACH call (one
        // outstanding at a time), and naïvely fire-and-forget drops every
        // call after the first. With unacked writes we can fill iOS's
        // outbound queue; when canSendWriteWithoutResponse returns false
        // we block until the delegate signals capacity is available.
        let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
        let chunkSize = max(20, min(mtu, 182))
        let writeType: CBCharacteristicWriteType = .withoutResponse
        let totalBytes = data.count

        DispatchQueue.global(qos: .userInitiated).async {
            print("writebytes: starting \(totalBytes) bytes, chunk=\(chunkSize), withoutResponse, mtu=\(mtu)")
            let startedAt = Date()
            var offset = 0
            while offset < totalBytes {
                // Block here if iOS's outbound queue is full. We mark the
                // queue as blocked so the delegate knows to signal us.
                var canSend = false
                DispatchQueue.main.sync {
                    canSend = peripheral.canSendWriteWithoutResponse
                    if !canSend { self.writeQueueIsBlocked = true }
                }
                if !canSend {
                    // Wait up to 5s for capacity. If timeout, abort.
                    let waitResult = self.writeReadySemaphore.wait(timeout: .now() + 5.0)
                    if waitResult == .timedOut {
                        print("writebytes: timed out waiting for BLE queue capacity at offset \(offset)")
                        DispatchQueue.main.async { result(false) }
                        return
                    }
                }

                let chunkRange = offset..<min(offset + chunkSize, totalBytes)
                let chunkData = data.subdata(in: chunkRange)
                DispatchQueue.main.sync {
                    peripheral.writeValue(chunkData, for: characteristic, type: writeType)
                }
                offset += chunkSize
            }
            let elapsed = Date().timeIntervalSince(startedAt)
            print("writebytes: SENT \(totalBytes) bytes in \(String(format: "%.2f", elapsed))s")
            DispatchQueue.main.async {
                result(true)
            }
        }
        return

      } else if call.method == "writebytesraw" {
        // Fast-path: bytes arrive as FlutterStandardTypedData (Uint8List on
        // the Dart side) so no per-element boxing is required.
        guard let typed = call.arguments as? FlutterStandardTypedData else {
            print("writebytesraw: invalid arguments")
            result(false)
            return
        }
        let data = typed.data

        guard let characteristic = targetCharacteristic else {
            print("writebytesraw: no target characteristic")
            result(false)
            return
        }

        // Send in 150-byte chunks (same as writebytes) to avoid saturating the
        // BLE write buffer. Use withResponse when the characteristic supports
        // it so flow-control back-pressure is honored.
        let chunkSize = 150
        var writeType: CBCharacteristicWriteType = .withoutResponse
        if characteristic.properties.contains(.write) {
            writeType = .withResponse
        }

        var offset = 0
        while offset < data.count {
            let chunkRange = offset..<min(offset + chunkSize, data.count)
            let chunkData = data.subdata(in: chunkRange)
            self.connectedPeripheral?.writeValue(chunkData, for: characteristic, type: writeType)
            offset += chunkSize
        }

        result(true)
        return
      } else if call.method == "printstring"{
        self.stringprint = call.arguments as! String
        //print("llego a printstring\(self.stringprint)")
        if let characteristic = targetCharacteristic {
            if self.stringprint.count > 0 {
                    //ver el tamaño del texto
                    var size = 0
                    var texto = ""
                    let linea = self.stringprint.components(separatedBy: "///")
                    if linea.count > 1 {
                        size = Int(linea[0]) ?? 0
                        texto = String(linea[1])
                        if size < 1 || size > 5 {
                            size = 2
                        }
                    } else {
                        size = 2
                        texto = self.stringprint
                    }
                    let sizeBytes: [[UInt8]] = [
                                [0x1d, 0x21, 0x00], // La fuente no se agranda 0
                                [0x1b, 0x4d, 0x01], // Fuente ASCII comprimida 1
                                [0x1b, 0x4d, 0x00], //Fuente estándar ASCII    2
                                [0x1d, 0x21, 0x11], // Altura doblada 3
                                [0x1d, 0x21, 0x22], // Altura doblada 4
                                [0x1d, 0x21, 0x33] // Altura doblada 5
                            ]
                    let resetBytes: [UInt8] = [0x1b, 0x40]

                    // Envío de los datos
                    let datasize = Data(sizeBytes[size])

                    var writeType = CBCharacteristicWriteType.withoutResponse;
                    if characteristic.properties.contains(.write) {
                        writeType = CBCharacteristicWriteType.withResponse;
                    }

                    connectedPeripheral?.writeValue(datasize, for: characteristic, type: writeType)

                    let data = Data(texto.utf8)
                    connectedPeripheral?.writeValue(data, for: characteristic, type: writeType)

                    // reseteo de la impresora
                    let datareset = Data(resetBytes)
                    connectedPeripheral?.writeValue(datareset, for: characteristic, type: writeType)
                    stringprint = ""

                    //la respuesta va en peripheral si es .withResponse
                    //self.flutterResult?(true)
                }
        } else {
            print("No hay caracteristica para imprimir")
            result(false)
        }
        } else if call.method == "disconnect"{
        if let peripheralToDisconnect = connectedPeripheral {
            centralManager?.cancelPeripheralConnection(peripheralToDisconnect)
        } else {
            // Nothing to disconnect from; reply success and clean state.
            self.flutterResult?(true)
        }
        targetCharacteristic = nil
        //la respuesta va en centralManager segunda funcion
        //result(true)
      } else {
        result(FlutterMethodNotImplemented) // Si se llama otro método que no está implementado, se devuelve un error
      }
  }

  
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        //print("Discovered \(peripheral.name ?? "Unknown") at \(RSSI) dBm")
        if let deviceName = peripheral.name {
            let deviceAddress = peripheral.identifier.uuidString
            //print("name \(deviceName) Address: \(deviceAddress)")
            let device = "\(deviceName)#\(deviceAddress)"
            if !discoveredDevices.contains(device) {
                discoveredDevices.append(device)
            }
        }
    }

    //funcion para verificar si desconecto el dispositivo
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if error != nil {
            //print("Error al desconectar del dispositivo: \(error!.localizedDescription)")
            self.flutterResult?(false)
        } else {
        //print("Se ha desconectado del dispositivo con éxito")
         self.flutterResult?(true)
        }
    }

     //detectar los servicios descubiertos y guardarlo para poder imprimir
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
           if let error = error {
               print("Error discovering services: \(error.localizedDescription)")
               return
           }

           if let services = peripheral.services {
               for service in services {
                   print("Service discovered: \(service.uuid)")
                   let allowedServices = [
                        CBUUID(string: "00001101-0000-1000-8000-00805F9B34FB"),
                        CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455"),
                        CBUUID(string: "A76EB9E0-F3AC-4990-84CF-3A94D2426B2B")
                   ]

                   if allowedServices.contains(service.uuid) {
                       print("Service found: \(service.uuid)") 
                       // Por ejemplo, puedes descubrir las características del servicio
                       peripheral.discoverCharacteristics(nil, for: service)

                       // También puedes almacenar el servicio en una variable para futuras referencias
                       // targetService = service
                       self.targetService = service;
                   }

                   // Aquí puedes realizar operaciones adicionales con cada servicio encontrado, como descubrir características
                   peripheral.discoverCharacteristics(nil, for: service)
               }
           }
    }

    // Implementación del método peripheral(_:didDiscoverCharacteristicsFor:error:) para buscar las caracteristicas del dispositivo bluetooth
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("Error discovering characteristics: \(error.localizedDescription)")
            return
        }

        if let discoveredCharacteristics = service.characteristics {
            for characteristic in discoveredCharacteristics {
                //print("characteristics found: \(characteristic.uuid)")
            
                let allowedCharacteristics = [
                    CBUUID(string: "00001101-0000-1000-8000-00805F9B34FB"), 
                    CBUUID(string: "49535343-8841-43F4-A8D4-ECBE34729BB3"), 
                    CBUUID(string: "A76EB9E2-F3AC-4990-84CF-3A94D2426B2B")
                ]

                if allowedCharacteristics.contains(characteristic.uuid) {
                    targetCharacteristic = characteristic // Guarda la característica objetivo en la variable global
                    print("Target characteristic found: \(characteristic.uuid)")
                 
                    if characteristic.properties.contains(.write) {
                        // La característica admite escritura
                        print("characteristics found: \(characteristic.uuid) La característica admite escritura")
                    } else {
                        // La característica no admite escritura
                        print("characteristics found: \(characteristic.uuid) La característica no admite escritura")
                    }
                    break
                }
            }
        }
    }

    // Implementación del método peripheral(_:didWriteValueFor:error:) para saber si la impresion fue exitosa si se pasa .withResponse
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
           print("Error al escribir en la característica: \(error.localizedDescription)")
            self.flutterResult?(false)
           return
        }
         self.flutterResult?(true)
        // Aquí puedes realizar operaciones adicionales con la respuesta de la escritura
    }

    // Flow control for .withoutResponse writes — fires when iOS has freed
    // capacity in its outbound BLE queue. We wake the writebytes worker
    // thread so it can send the next chunk.
    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if self.writeQueueIsBlocked {
            self.writeQueueIsBlocked = false
            self.writeReadySemaphore.signal()
        }
    }
    
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
            case .poweredOn:
                // El bluetooth está encendido y listo para usar
                print("Bluetooth está encendido")
            case .poweredOff:
                // El bluetooth está apagado
                print("Bluetooth está apagado")
            case .resetting:
                // El bluetooth está reiniciándose
                print("Bluetooth está reiniciándose")
            case .unauthorized:
                // La app no tiene permiso para usar el bluetooth
                print("La app no tiene permiso para usar el bluetooth")
            case .unsupported:
                // El dispositivo no soporta el bluetooth
                print("El dispositivo no soporta el bluetooth")
            case .unknown:
                // El estado del bluetooth es desconocido
                print("El estado del bluetooth es desconocido")
            @unknown default:
                // Otro caso no esperado
                print("Otro caso no esperado")
        }
    }

}


