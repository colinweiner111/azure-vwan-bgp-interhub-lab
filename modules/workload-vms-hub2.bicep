// =============================================================================
// Workload VMs Module - Hub2 Test VMs for connectivity validation
// =============================================================================
// Creates Ubuntu VMs in:
// - Spoke 3 workloads subnet (10.110.1.0/24) connected to hub2
// - Spoke 4 workloads subnet (10.210.1.0/24) connected to hub2
// =============================================================================

param location string
param adminUsername string
@secure()
param adminPassword string
param vmSize string = 'Standard_B2s'
param spoke3SubnetId string
param spoke4SubnetId string

// =============================================================================
// Spoke 3 Workload VM
// =============================================================================
resource spoke3Nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'spoke3-vm-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.110.1.10'
          subnet: {
            id: spoke3SubnetId
          }
        }
      }
    ]
  }
}

resource spoke3Vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'spoke3-vm'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: 'spoke3-vm'
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
          id: spoke3Nic.id
        }
      ]
    }
  }
}

// =============================================================================
// Spoke 4 Workload VM
// =============================================================================
resource spoke4Nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'spoke4-vm-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.210.1.10'
          subnet: {
            id: spoke4SubnetId
          }
        }
      }
    ]
  }
}

resource spoke4Vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'spoke4-vm'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: 'spoke4-vm'
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
          id: spoke4Nic.id
        }
      ]
    }
  }
}

// =============================================================================
// Outputs
// =============================================================================
output spoke3VmPrivateIp string = spoke3Nic.properties.ipConfigurations[0].properties.privateIPAddress
output spoke4VmPrivateIp string = spoke4Nic.properties.ipConfigurations[0].properties.privateIPAddress
