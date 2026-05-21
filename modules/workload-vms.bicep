// =============================================================================
// Workload VMs Module - Test VMs for connectivity validation
// =============================================================================
// Creates Ubuntu VMs in:
// - On-prem workloads subnet (10.0.1.0/24)
// - Spoke 1 workloads subnet (10.100.1.0/24)
// - Spoke 2 workloads subnet (10.200.1.0/24)
// =============================================================================

param location string
param adminUsername string
@secure()
param adminPassword string
param vmSize string = 'Standard_B2s'
param onpremSubnetId string
param spoke1SubnetId string
param spoke2SubnetId string

// =============================================================================
// On-Prem Workload VM
// =============================================================================
resource onpremNic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'onprem-vm-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.0.1.10'
          subnet: {
            id: onpremSubnetId
          }
        }
      }
    ]
  }
}

resource onpremVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'onprem-vm'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: 'onprem-vm'
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: onpremNic.id
        }
      ]
    }
  }
}

// =============================================================================
// Spoke 1 Workload VM
// =============================================================================
resource spoke1Nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'spoke1-vm-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.100.1.10'
          subnet: {
            id: spoke1SubnetId
          }
        }
      }
    ]
  }
}

resource spoke1Vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'spoke1-vm'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: 'spoke1-vm'
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: spoke1Nic.id
        }
      ]
    }
  }
}

// =============================================================================
// Spoke 2 Workload VM
// =============================================================================
resource spoke2Nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'spoke2-vm-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.200.1.10'
          subnet: {
            id: spoke2SubnetId
          }
        }
      }
    ]
  }
}

resource spoke2Vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'spoke2-vm'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: 'spoke2-vm'
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: spoke2Nic.id
        }
      ]
    }
  }
}

// =============================================================================
// Outputs
// =============================================================================
output onpremVmPrivateIp string = onpremNic.properties.ipConfigurations[0].properties.privateIPAddress
output spoke1VmPrivateIp string = spoke1Nic.properties.ipConfigurations[0].properties.privateIPAddress
output spoke2VmPrivateIp string = spoke2Nic.properties.ipConfigurations[0].properties.privateIPAddress
