/*
 * Copyright (c) 2017, Psiphon Inc.
 * All rights reserved.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#import <NetworkExtension/NetworkExtension.h>
#import "VPNManager.h"
#import "PsiphonDataSharedDB.h"
#import "SharedConstants.h"
#import "Notifier.h"

#define TAG_VPN_MANAGER @"VPNManager"

@interface VPNManager ()

@property (nonatomic) NEVPNManager *targetManager;

@end

@implementation VPNManager {
    Notifier *notifier;
    PsiphonDataSharedDB *sharedDB;
    id localVPNStatusObserver;
    BOOL restartRequired;
}

@synthesize targetManager = _targetManager;

- (instancetype)init {
    self = [super init];
    if (self) {
        notifier = [[Notifier alloc] initWithAppGroupIdentifier:APP_GROUP_IDENTIFIER];
        sharedDB = [[PsiphonDataSharedDB alloc] initForAppGroupIdentifier:APP_GROUP_IDENTIFIER];

        self.targetManager = [NEVPNManager sharedManager];

        // Load previous NETunnelProviderManager, if any.
        [NETunnelProviderManager loadAllFromPreferencesWithCompletionHandler:
          ^(NSArray<NETunnelProviderManager *> *managers, NSError *error) {
              if ([managers count] == 1) {
                  self.targetManager = managers[0];
              }
          }];
    }
    return self;
}

#pragma mark - Public methods

+ (instancetype)sharedInstance {
    static dispatch_once_t once;
    static id sharedInstance;
    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (VPNStatus)getVPNStatus {
    if (restartRequired) {
        return VPNStatusRestarting;
    } else {
        switch (self.targetManager.connection.status) {
            case NEVPNStatusInvalid: return VPNStatusInvalid;
            case NEVPNStatusDisconnected: return VPNStatusDisconnected;
            case NEVPNStatusConnecting: return VPNStatusConnecting;
            case NEVPNStatusConnected: return VPNStatusConnected;
            case NEVPNStatusReasserting: return VPNStatusReasserting;
            case NEVPNStatusDisconnecting: return VPNStatusDisconnecting;
        }
    }
}

- (void)startTunnelWithCompletionHandler:(nullable void (^)(NSError * _Nullable error))completionHandler {

    // Reset restartRequired flag
    restartRequired = FALSE;

    [NETunnelProviderManager loadAllFromPreferencesWithCompletionHandler:
      ^(NSArray<NETunnelProviderManager *> * _Nullable allManagers, NSError * _Nullable error) {

        if (error) {
            if (completionHandler) {
                NSLog(@"%@", error);
                completionHandler([VPNManager errorWithCode:VPNManagerErrorLoadConfigsFailed]);
            }
            return;
        }

        // If there are no configurations, create one
        // if there is more than one, abort!
        if ([allManagers count] == 0) {
            NSLog(@"startTunnel: np VPN configurations found");
            NETunnelProviderManager *newManager = [[NETunnelProviderManager alloc] init];
            NETunnelProviderProtocol *providerProtocol = [[NETunnelProviderProtocol alloc] init];
            providerProtocol.providerBundleIdentifier = @"ca.psiphon.Psiphon.PsiphonVPN";
            newManager.protocolConfiguration = providerProtocol;
            newManager.protocolConfiguration.serverAddress = @"localhost";
            self.targetManager = newManager;
        } else if ([allManagers count] > 1) {
            NSLog(@"startTunnel: %lu VPN configurations found, only expected 1. Aborting", (unsigned long)[allManagers count]);
            if (completionHandler) {
                completionHandler([VPNManager errorWithCode:VPNManagerErrorTooManyConfigsFounds]);
            }
            return;
        }

        // setEnabled becomes false if the user changes the
        // enabled VPN Configuration from the prefrences.
        [self.targetManager setEnabled:TRUE];


        NSLog(@"startTunnel: call saveToPreferencesWithCompletionHandler");

        [self.targetManager saveToPreferencesWithCompletionHandler:^(NSError * _Nullable error) {
            if (error != nil) {
                // User denied permission to add VPN Configuration.
                NSLog(@"startTunnel: failed to save the configuration: %@", error);
                if (completionHandler) {
                    completionHandler([VPNManager errorWithCode:VPNManagerErrorUserDeniedConfigInstall]);
                }
                return;
            }

            [self.targetManager loadFromPreferencesWithCompletionHandler:^(NSError * _Nullable error) {
                if (error != nil) {
                    NSLog(@"startTunnel: second loadFromPreferences failed");
                    if (completionHandler) {
                        completionHandler([VPNManager errorWithCode:VPNManagerErrorLoadConfigsFailed]);
                    }
                    return;
                }

                NSLog(@"startTunnel: call targetManager.connection.startVPNTunnel()");
                NSError *vpnStartError;
                NSDictionary *extensionOptions = @{EXTENSION_OPTION_START_FROM_CONTAINER : @YES};

                BOOL vpnStartSuccess = [self.targetManager.connection startVPNTunnelWithOptions:extensionOptions
                                                                                 andReturnError:&vpnStartError];
                if (!vpnStartSuccess) {
                    NSLog(@"startTunnel: startVPNTunnel failed: %@", vpnStartError);
                    if (completionHandler) {
                        completionHandler([VPNManager errorWithCode:VPNManagerErrorNEStartFailed]);
                    }
                    return;
                }

                NSLog(@"startTunnel: startVPNTunnel success");
                if (completionHandler) {
                    completionHandler(nil);
                }
            }];
        }];
    }];
}

- (void)startVPN {
    NEVPNStatus s = self.targetManager.connection.status;
    if (s == NEVPNStatusConnecting) {
        [notifier post:@"M.startVPN"];
    } else {
        NSLog(TAG_VPN_MANAGER @"startVPN: Network extension is not in connecting state.");
    }
}

- (void)restartVPN {
    if (self.targetManager.connection) {
        restartRequired = YES;
        [self.targetManager.connection stopVPNTunnel];
    }
}


- (void)stopVPN {
    if (self.targetManager.connection) {
        [self.targetManager.connection stopVPNTunnel];
    }
}

- (BOOL)isVPNActive {
    NEVPNStatus s = self.targetManager.connection.status;
    return (s == NEVPNStatusConnecting || s == NEVPNStatusConnected || s == NEVPNStatusReasserting);
}

- (BOOL)isTunnelConnected {
    return [self isVPNActive] && [sharedDB getTunnelConnectedState];
}

#pragma mark - Private methods

- (void)setTargetManager:(NEVPNManager *)targetManager {

    _targetManager = targetManager;
    [self postStatusChangeNotification];

    // Listening to NEVPNManager status change notifications.
    localVPNStatusObserver = [[NSNotificationCenter defaultCenter]
      addObserverForName:NEVPNStatusDidChangeNotification
      object:_targetManager.connection queue:NSOperationQueue.mainQueue
      usingBlock:^(NSNotification * _Nonnull note) {

          // Observers of kVPNStatusChangeNotificationName will be notified at the same time.
          [self postStatusChangeNotification];

          // To restart the VPN, should wait till NEVPNStatusDisconnected is received.
          // We can then start a new tunnel.
          // If restartRequired then start  a new network extension process if the previous
          // one has already been disconnected.
          if (_targetManager.connection.status == NEVPNStatusDisconnected && restartRequired) {
              dispatch_async(dispatch_get_main_queue(), ^{
                  [self startTunnelWithCompletionHandler:nil];
              });
          }

      }];
}

- (void)postStatusChangeNotification {
    [[NSNotificationCenter defaultCenter]
      postNotificationName:@kVPNStatusChangeNotificationName object:self];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:localVPNStatusObserver];
}

+ (NSError *)errorWithCode:(VPNManagerErrorCode)code {
    return [[NSError alloc] initWithDomain:kVPNManagerErrorDomain code:code userInfo:nil];
}

@end
