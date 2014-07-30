//
//  VeraController.m
//  Home
//
//  Created by Drew Ingebretsen on 2/25/13.
//  Copyright (c) 2013 PeopleTech. All rights reserved.
//

#import "VeraController.h"
#import "ZwaveDimmerSwitch.h"
#import "ZwaveSwitch.h"
#import "ZwaveLock.h"
#import "ZWaveThermostat.h"
#import "ZWaveHumiditySensor.h"
#import "ZwaveSecuritySensor.h"
#import "PhillipsHueBulb.h"
#import "IPCamera.h"
#import "VeraRoom.h"
#import "VeraScene.h"

#import <CommonCrypto/CommonDigest.h>

//This is the default forward server
#define FORWARD_SERVER_DEFAULT @"fwd5.mios.com"

@interface VeraController()
@property (nonatomic, strong) NSTimer *heartBeat;

@property (nonatomic, strong) NSArray *rooms;
@property (nonatomic, strong) NSArray *scenes;
@property (nonatomic, strong) NSArray *switches;
@property (nonatomic, strong) NSArray *locks;
@property (nonatomic, strong) NSArray *dimmerSwitches;
@property (nonatomic, strong) NSArray *securitySensors;
@property (nonatomic, strong) NSArray *thermostats;
@property (nonatomic, strong) NSArray *hueBulbs;
@property (nonatomic, strong) NSArray *ipCameras;
@end

@implementation VeraController

-(id)init{
    self = [super init];
    if (self){
        self.switches = @[];
        self.dimmerSwitches = @[];
        self.locks = @[];
        self.thermostats = @[];
        self.securitySensors = @[];
        self.hueBulbs = @[];
        self.ipCameras = @[];
    }
    return self;
}

-(void)startHeartbeatWithInterval:(NSInteger)interval{
    if (self.heartBeat == nil || ![self.heartBeat isValid]) {
        self.heartBeat = [NSTimer scheduledTimerWithTimeInterval:interval target:self selector:@selector(refreshDevices) userInfo:nil repeats:YES];
        [self.heartBeat fire];
    }
}

-(void)stopHeartbeat{
    if (self.heartBeat == nil)
        return;
    
    [self.heartBeat invalidate];
}

+(void)findVeraControllers:(NSString*)miosUsername password:(NSString*)miosPassword completion:(void(^)(NSArray *units, NSError *error))completionBlock{
    NSString *locateUrl;
    if (miosUsername.length == 0){
        locateUrl = [NSString stringWithFormat:@"https://sta1.mios.com/locator_json.php?username=user"];
    }
    else{
        locateUrl = [NSString stringWithFormat:@"https://sta1.mios.com/locator_json.php?username=%@", miosUsername];
    }

    [NSURLConnection sendAsynchronousRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:locateUrl]] queue:[[NSOperationQueue alloc] init] completionHandler:^(NSURLResponse *response, NSData *data, NSError *error){
        if (error){
            NSLog(@"%@", error.localizedDescription);
            if (completionBlock){
            dispatch_async(dispatch_get_main_queue(), ^{
                    completionBlock(nil, error);
                });
            }
            return;
        }
        
        NSDictionary *miosLocatorResponse = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:nil];
        NSArray *units = miosLocatorResponse[@"units"];
        // TODO: notify callback if no units are returned
        if (units.count > 0){
            NSMutableArray *veraDevices = [[NSMutableArray alloc] init];
            for (NSDictionary *unitDictionary in units){
                VeraController *veraController = [[VeraController alloc] init];
                veraController.veraSerialNumber = unitDictionary[@"serialNumber"];
                veraController.ipAddress = unitDictionary[@"ipAddress"];
                veraController.miosUsername = miosUsername;
                veraController.miosPassword = miosPassword;
                veraController.miosHostname = unitDictionary[@"active_server"];
                veraController.useMiosRemoteService = (veraController.ipAddress.length < 7);
                [veraDevices addObject:veraController];
            }
            if (completionBlock){
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionBlock(veraDevices, nil);
                });
            }
            
            [[NSNotificationCenter defaultCenter] postNotificationName:VERA_LOCATE_CONTROLLER_NOTIFICATION object:nil];
            
        }
        else {
            //There was an error locating the device, probably due to bad credentials
            [[NSNotificationCenter defaultCenter] postNotificationName:VERA_LOCATE_CONTROLLER_NOTIFICATION object:[NSError errorWithDomain:@"VeraControl - Could not locate Vera Controller" code:50 userInfo:nil]];
        }
    }];
    
}

-(void)testReachability:(void(^)(BOOL reachable))completion{
    if (!completion){
        return;
    }
    
    [self performCommand:@"id=alive" completion:^(NSURLResponse *response, NSData *data, NSError *error){
        if (error){
            completion(NO);
            return;
        }
        
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*)response;
        if (httpResponse.statusCode != 200){
            completion(NO);
            return;
        }
        
        NSString *responseString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        completion([responseString isEqualToString:@"OK"]);
    }];
}

-(NSString *)controlUrl{
    if ([self isUI6]) {
        if (self.useMiosRemoteService) {
            return [NSString stringWithFormat:@"https://%@/relay/relay/relay/device/%@/port_3480", self.relayServer, self.veraSerialNumber];
        } else {
            // TODO: local access for UI6
            return nil;
        }
        
    } else {
        if (self.miosHostname.length == 0)
            self.miosHostname = FORWARD_SERVER_DEFAULT;
        
        if (self.useMiosRemoteService || self.ipAddress.length == 0){
            if ([self.veraSerialNumber length] == 0)
                return [NSString stringWithFormat:@"https://%@/%@/%@", self.miosHostname, self.miosUsername, self.miosPassword];
            return [NSString stringWithFormat:@"https://%@/%@/%@/%@", self.miosHostname, self.miosUsername, self.miosPassword, self.veraSerialNumber];
        }
        else{
            return [NSString stringWithFormat:@"http://%@:3480", self.ipAddress];
        }
    }
}

-(void)performCommand:(NSString*)command completion:(void(^)(NSURLResponse *response, NSData *data, NSError *devices))callback{
    NSString *urlString = [NSString stringWithFormat:@"%@/data_request?%@",[self controlUrl], command];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    BOOL execute = YES;
    if ([self isUI6]) {
        if (self.sessionToken) {
            [request addValue:self.sessionToken forHTTPHeaderField:@"MMSSession"];
        } else {
            [VeraController requestSessionTokenForServer:self.relayServer
                               withAuthenticatorResponse:self.miosAuthenticatorResponse
                                       completionHandler:^(NSString *sessionToken, NSError *sessionError) {
                                           if (sessionToken) {
                                               self.sessionToken = sessionToken;
                                               [self performCommand:command completion:callback];
                                           } else {
                                               if (callback) {
                                                   callback(nil, nil, sessionError);
                                               }
                                           }
                                       }];
            execute = NO;
        }
    }
    
    if (execute) {
        [NSURLConnection sendAsynchronousRequest:request queue:[[NSOperationQueue alloc] init] completionHandler:^(NSURLResponse *response, NSData *data, NSError *error){
            callback(response, data, error);
        }];
    }
}

-(void)refreshDevices{
    [self performCommand:@"id=user_data" completion:^(NSURLResponse *response, NSData *data, NSError *error){
        NSHTTPURLResponse *r = (NSHTTPURLResponse*)response;
        
        if (r.statusCode !=200){
            if (!self.useMiosRemoteService){
                self.useMiosRemoteService = YES;
                [self refreshDevices];
            }
            return;
        }
        
        NSDictionary *responseDictionary = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:&error];
        
        if (error != nil) {
            //There was an error processing JSON, this happens if username/password is invalid
            [[NSNotificationCenter defaultCenter] postNotificationName:VERA_DEVICES_DID_REFRESH_NOTIFICATION object:[NSError errorWithDomain:@"VeraControl - Error refreshing devices" code:50 userInfo:error.userInfo]];
            return;
        }
        
        //Gather the rooms
        NSArray *parsedRooms = responseDictionary[@"rooms"];
        
        if (self.roomsDictionary == nil) {
            self.roomsDictionary = [[NSMutableDictionary alloc] initWithCapacity:(parsedRooms.count+1)];
            
            VeraRoom *unassignedRoom = [[VeraRoom alloc] init];
            unassignedRoom.name = @"Unassigned";
            unassignedRoom.identifier = @"0";
            unassignedRoom.section = @"0";
            
            [self.roomsDictionary setObject:unassignedRoom forKey:unassignedRoom.identifier];
        }
        
        //Add the unassigned room
        self.rooms = @[[self.roomsDictionary objectForKey:@"0"]];
        
        for (NSDictionary *parsedRoom in parsedRooms){
            //Check to see if the room exists and update it, if not create one
            NSString *identifier = [[parsedRoom objectForKey:@"id"] stringValue];
            VeraRoom *room = self.roomsDictionary[identifier];
            
            if (room == nil) {
                VeraRoom *room = [[VeraRoom alloc] init];
                room.name = [parsedRoom objectForKey:@"name"];
                room.identifier = [[parsedRoom objectForKey:@"id"] stringValue];
                room.section = [parsedRoom objectForKey:@"section"];
                self.rooms = [self.rooms arrayByAddingObject:room];
                [self.roomsDictionary setObject:room forKey:room.identifier];
            }
            else {
                room.name = [parsedRoom objectForKey:@"name"];
                room.identifier = [[parsedRoom objectForKey:@"id"] stringValue];
                room.section = [parsedRoom objectForKey:@"section"];
                
                //Clear the devices since we are going to refill it
                //TODO: We should create a devices dictionary as well
                room.devices = @[];
            }
        }
        
        //Gather the devices
        NSArray *devices = responseDictionary[@"devices"];
        
        if (self.deviceDictionary == nil) {
            self.deviceDictionary = [[NSMutableDictionary alloc] initWithCapacity:devices.count];
        }
        
        for (NSDictionary *deviceData in devices){
            NSString *deviceType = deviceData[@"device_type"];
            NSString *deviceIdentifier = deviceData[@"id"];
            
            ZwaveNode *device = self.deviceDictionary[deviceIdentifier];
            
            if (device == nil) {
                //Create a new ZWaveNode based on deviceType
                
                if ([deviceType isEqualToString:UPNP_DEVICE_TYPE_DIMMABLE_SWITCH]){
                    device = [[ZwaveDimmerSwitch alloc] initWithDictionary:deviceData];
                    self.dimmerSwitches = [self.dimmerSwitches arrayByAddingObject:device];
                }
                
                
                if ([deviceType isEqualToString:UPNP_DEVICE_TYPE_SWITCH]){
                    device = [[ZwaveSwitch alloc] initWithDictionary:deviceData];
                    self.switches = [self.switches arrayByAddingObject:device];
                }
                
                if ([deviceType isEqualToString:UPNP_DEVICE_TYPE_DOOR_LOCK]){
                    device = [[ZwaveLock alloc] initWithDictionary:deviceData];
                    self.locks = [self.locks arrayByAddingObject:device];
                }
                
                if ([deviceType isEqualToString:UPNP_DEVICE_TYPE_THERMOSTAT]){
                    device = [[ZwaveThermostat alloc] initWithDictionary:deviceData];
                    self.thermostats = [self.thermostats arrayByAddingObject:device];
                }
                
                if ([deviceType isEqualToString:UPNP_DEVICE_TYPE_NEST_THERMOSTAT]){
                    device = [[ZwaveThermostat alloc] initWithDictionary:deviceData];
                    self.thermostats = [self.thermostats arrayByAddingObject:device];
                }
                
                if ([deviceType isEqualToString:UPNP_DEVICE_TYPE_MOTION_SENSOR]){
                    device = [[ZwaveSecuritySensor alloc] initWithDictionary:deviceData];
                    self.securitySensors = [self.securitySensors arrayByAddingObject:device];
                }
                
                if ([deviceType isEqualToString:UPNP_DEVICE_TYPE_PHILLIPS_HUE_BULB]){
                    device = [[PhillipsHueBulb alloc] initWithDictionary:deviceData];
                    self.hueBulbs = [self.hueBulbs arrayByAddingObject:device];
                }
                
                if ([deviceType isEqualToString:UPNP_DEVICE_TYPE_IP_CAMERA]){
                    device = [[IPCamera alloc] initWithDictionary:deviceData];
                    self.ipCameras = [self.ipCameras arrayByAddingObject:device];
                }
                
                if (device)
                    [self.deviceDictionary setObject:device forKey:deviceIdentifier];
            }
            
            else {
                //Update the device
                [device updateWithDictionary:deviceData];
            }
            
            //Add the device to the room
            if (device){
                device.controllerUrl = [self controlUrl];
                VeraRoom *room = [self.roomsDictionary objectForKey:device.room];
                NSAssert((room != nil), @"Room does not exist - %@", device.room);
                
                //Scan the array to see if the device is already added to the room
                //TODO: This might make sense being a dictionary as well. Also need to deal with device being removed from a room.
                NSArray *array = [room.devices filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"identifier == %@", device.identifier]];
                if (array.count == 0){
                    //Device not found, add it
                    room.devices = [room.devices arrayByAddingObject:device];
                }

            }
        }
        
        
        //Get Scenes
        self.scenes = @[];
        
        //Clear all the room scenes
        //TODO: Make scenes an updateable dictionary like rooms and devices
        for (id roomid in self.roomsDictionary) {
            VeraRoom *room = [self.roomsDictionary objectForKey:roomid];
            room.scenes = @[];
        }
        
        NSArray *scenes = responseDictionary[@"scenes"];
        for (NSDictionary *dictionary in scenes){
            VeraScene *scene = [[VeraScene alloc] initWithDictionary:dictionary];
            scene.controllerUrl = [self controlUrl];
            self.scenes = [self.scenes arrayByAddingObject:scene];
            
            VeraRoom *room = [self.roomsDictionary objectForKey:scene.room];
            NSAssert((room != nil), @"Room does not exist - %@", scene.room);
            NSArray *array = [room.scenes filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"sceneNum == %@", scene.sceneNum]];
            if (array.count == 0){
                //Scene not found, add it
                //TODO: deal with device removals
                room.scenes = [room.scenes arrayByAddingObject:scene];
            }
        }
        
        dispatch_async(dispatch_get_main_queue(), ^(){
            [[NSNotificationCenter defaultCenter] postNotificationName:VERA_DEVICES_DID_REFRESH_NOTIFICATION object:nil];
        });
        
    }];
}

-(VeraScene*)getEmptyScene{
    VeraScene *scene = [[VeraScene alloc] init];
    scene.controllerUrl = [self controlUrl];
    scene.name = @"New Scene";
    scene.triggers = @[];
    scene.actions = @[];
    scene.schedules = @[];
    return scene;
}


#define NSCoding

-(NSArray*)propertiesToCode{
    
     //@"miosUsername",@"miosPassword", @"ipAddress", @"veraSerialNumber", @"useMiosRemoteService",@"miosHostname"
    
    
    return @[];
}



#pragma mark - UI6

-(BOOL)isUI6;
{
    return (self.relayServer.length>0);
}

+ (NSString *)sha1For:(NSString *)string;
{
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    
    CC_SHA1(data.bytes, data.length, digest);
    
    NSMutableString *output = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [output appendFormat:@"%02x", digest[i]];
    }
    
    return output;
}

+(void)requestSessionTokenForServer:(NSString *)server withAuthenticatorResponse:(NSDictionary *)miosAuthenticatorResponse completionHandler:(void (^)(NSString *sessionToken, NSError *error))handler;
{
    NSString *authToken = miosAuthenticatorResponse[@"Identity"];
    NSString *authSigToken = miosAuthenticatorResponse[@"IdentitySignature"];
    
    NSString *urlString = [NSString stringWithFormat:@"https://%@/info/session/token", server];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    [request addValue:authToken forHTTPHeaderField:@"MMSAuth"];
    [request addValue:authSigToken forHTTPHeaderField:@"MMSAuthSig"];

    [NSURLConnection sendAsynchronousRequest:request queue:[[NSOperationQueue alloc] init] completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError) {
        
        NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSInteger statusCode = httpResponse.statusCode;
        if (statusCode>=200 && statusCode<300) {
            
            NSString *sessionToken = [[NSString alloc ] initWithData:data encoding:NSUTF8StringEncoding];
            if (handler) {
                handler(sessionToken, nil);
            }
        } else {
            if (handler) {
                NSError *error = [NSError errorWithDomain:[NSString stringWithFormat:@"VeraControl - Could not get Session Token for server %@", server] code:50 userInfo:nil];
                handler(nil, error);
            }
        }
    }];
}

+(void)authenticateWithUsername:(NSString *)miosUsername password:(NSString *)miosPassword completionHandler:(void (^)(NSDictionary *miosAuthenticatorResponse, NSError *error))handler;
{
    NSString *miosLowercaseUsername = [miosUsername lowercaseString];
    NSString *passwordSeed = @"oZ7QE6LcLJp6fiWzdqZc";
    NSString *sha1String = [NSString stringWithFormat:@"%@%@%@", miosLowercaseUsername, miosPassword, passwordSeed];
    NSString *passwordSHA1 = [self sha1For:sha1String];
    
    NSString *stringURL = [NSString stringWithFormat:@"https://vera-us-oem-autha12.mios.com/autha/auth/username/%@?SHA1Password=%@&PK_Oem=1", miosLowercaseUsername, passwordSHA1];
    NSURL *url = [NSURL URLWithString:stringURL];
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    
    [NSURLConnection sendAsynchronousRequest:request queue:[[NSOperationQueue alloc] init] completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSInteger statusCode = httpResponse.statusCode;
        if (statusCode>=200 && statusCode<300) {
            NSDictionary *miosAuthenticatorResponse = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:nil];
            if (handler) {
                handler(miosAuthenticatorResponse, nil);
            }
        } else {
            if (handler) {
                handler(nil, connectionError);
            }
        }
    }];
    
}

+(void)findUI6VeraControllers:(NSString*)miosUsername password:(NSString*)miosPassword completion:(void(^)(NSArray *units, NSError *error))completionBlock;
{
    // Based on:
    // http://forum.micasaverde.com/index.php/topic,24942.0.html
    
    
    [self authenticateWithUsername:miosUsername password:miosPassword completionHandler:^(NSDictionary *miosAuthenticatorResponse, NSError *error) {
        
        if (miosAuthenticatorResponse) {
            NSString *authToken = miosAuthenticatorResponse[@"Identity"];
            NSData *decodedAuthTokenData = [[NSData alloc] initWithBase64EncodedString:authToken options:0];
            NSDictionary *authTokenJSON = [NSJSONSerialization JSONObjectWithData:decodedAuthTokenData options:NSJSONReadingAllowFragments error:nil];
            NSString *pkAccount = authTokenJSON[@"PK_Account"];
            NSString *serverAccount = miosAuthenticatorResponse[@"Server_Account"];
            
            [self requestSessionTokenForServer:@"vera-us-oem-authd12.mios.com" withAuthenticatorResponse:miosAuthenticatorResponse completionHandler:^(NSString *sessionToken, NSError *error) {
                
                if (sessionToken) {
                    NSString *urlString = [NSString stringWithFormat:@"https://%@/account/account/account/%@/devices",
                                           serverAccount, pkAccount];
                    NSURL *url = [NSURL URLWithString:urlString];
                    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
                    [request addValue:sessionToken forHTTPHeaderField:@"MMSSession"];
                    [NSURLConnection sendAsynchronousRequest:request queue:[[NSOperationQueue alloc] init] completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError) {
                        
                        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                        NSInteger statusCode = httpResponse.statusCode;
                        if (statusCode>=200 && statusCode<300) {
                            
                            NSDictionary *devicesResponse = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:nil];
                            NSMutableArray *veraDevices = [[NSMutableArray alloc] init];
                            NSArray *units = devicesResponse[@"Devices"];
                            for (int i=0; i<units.count; i++) {
                                NSDictionary *unitDictionary = units[i];
                                NSString *pkDevice = unitDictionary[@"PK_Device"];
                                NSString *serverDevice = unitDictionary[@"Server_Device"];
                                NSString *urlString = [NSString stringWithFormat:@"https://%@/device/device/device/%@", serverDevice, pkDevice];
                                NSURL *url = [NSURL URLWithString:urlString];
                                NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
                                [request addValue:sessionToken forHTTPHeaderField:@"MMSSession"];
                                [NSURLConnection sendAsynchronousRequest:request queue:[[NSOperationQueue alloc] init] completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError) {
                                    
                                    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                                    NSInteger statusCode = httpResponse.statusCode;
                                    if (statusCode>=200 && statusCode<300) {
                                        
                                        NSDictionary *unitResponse = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:nil];
                                        
                                        VeraController *veraController = [[VeraController alloc] init];
                                        veraController.veraSerialNumber = pkDevice;
                                        veraController.ipAddress = unitResponse[@"InternalIP"];
                                        veraController.relayServer = unitResponse[@"Server_Relay"];
                                        veraController.miosAuthenticatorResponse = miosAuthenticatorResponse;
                                        veraController.useMiosRemoteService = YES;
                                        [veraDevices addObject:veraController];
                                    }
                                    
                                    if (i==units.count-1) {
                                        // Done. Notify callback.
                                        if (completionBlock) {
                                            completionBlock(veraDevices, nil);
                                        }
                                    }
                                }];
                            }
                            
                        } else {
                            NSError *error = [NSError errorWithDomain:@"VeraControl - Could not get list of controllers" code:50 userInfo:nil];
                            if (completionBlock) {
                                completionBlock(nil, error);
                            }
                        }
                    }];
                    
                } else {
                    NSError *error = [NSError errorWithDomain:@"VeraControl - Could not get Session Token" code:50 userInfo:nil];
                    if (completionBlock) {
                        completionBlock(nil, error);
                    }
                }
                
            }];
            
            
            
        } else {
            error = [NSError errorWithDomain:@"VeraControl - Could not locate Vera Controller" code:50 userInfo:nil];
            if (completionBlock) {
                completionBlock(nil, error);
            }
        }
        
    }];
}



@end
