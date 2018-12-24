#import "AmapLocationPlugin.h"

#import <AMapFoundationKit/AMapFoundationKit.h>
#import <AMapLocationKit/AMapLocationKit.h>
#import <CoreLocation/CoreLocation.h>


/*
static NSDictionary* DesiredAccuracy = @{@"kCLLocationAccuracyBest":@(kCLLocationAccuracyBest),
                                         @"kCLLocationAccuracyNearestTenMeters":@(kCLLocationAccuracyNearestTenMeters),
                                         @"kCLLocationAccuracyHundredMeters":@(kCLLocationAccuracyHundredMeters),
                                         @"kCLLocationAccuracyKilometer":@(kCLLocationAccuracyKilometer),
                                         @"kCLLocationAccuracyThreeKilometers":@(kCLLocationAccuracyThreeKilometers),
                                         
                                         };*/
#define LAT_OFFSET_0(x,y) -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(fabs(x))
#define LAT_OFFSET_1 (20.0 * sin(6.0 * x * M_PI) + 20.0 * sin(2.0 * x * M_PI)) * 2.0 / 3.0
#define LAT_OFFSET_2 (20.0 * sin(y * M_PI) + 40.0 * sin(y / 3.0 * M_PI)) * 2.0 / 3.0
#define LAT_OFFSET_3 (160.0 * sin(y / 12.0 * M_PI) + 320 * sin(y * M_PI / 30.0)) * 2.0 / 3.0

#define LON_OFFSET_0(x,y) 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(fabs(x))
#define LON_OFFSET_1 (20.0 * sin(6.0 * x * M_PI) + 20.0 * sin(2.0 * x * M_PI)) * 2.0 / 3.0
#define LON_OFFSET_2 (20.0 * sin(x * M_PI) + 40.0 * sin(x / 3.0 * M_PI)) * 2.0 / 3.0
#define LON_OFFSET_3 (150.0 * sin(x / 12.0 * M_PI) + 300.0 * sin(x / 30.0 * M_PI)) * 2.0 / 3.0


#define RANGE_LON_MAX 137.8347
#define RANGE_LON_MIN 72.004
#define RANGE_LAT_MAX 55.8271
#define RANGE_LAT_MIN 0.8293
// jzA = 6378245.0, 1/f = 298.3
// b = a * (1 - f)
// ee = (a^2 - b^2) / a^2;
#define jzA 6378245.0
#define jzEE 0.00669342162296594323


FlutterEventSink   flutterLocationEventSink;
FlutterEventSink   flutterHeadingEventSink;

AMapLocationManager *locationManager;
 AMapLocatingCompletionBlock completionBlock;
FlutterMethodChannel* channel;

@interface AmapLocationPlugin()<AMapLocationManagerDelegate>

@end

static BOOL isConvertToWGS84;

@implementation AmapLocationPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    FlutterMethodChannel* channel = [FlutterMethodChannel
                                     methodChannelWithName:@"amap_location"
                                     binaryMessenger:[registrar messenger]];
    AmapLocationPlugin* instance = [[AmapLocationPlugin alloc] init];
    [registrar addMethodCallDelegate:instance channel:channel];
    
    LocationStreamHandler* locationStreamHandler = [[LocationStreamHandler alloc] init];
    FlutterEventChannel *locationChanel = [FlutterEventChannel eventChannelWithName:@"amap_location/location" binaryMessenger:registrar.messenger];
    
    HeadingStreamHandler* headingStreamHandler = [[HeadingStreamHandler alloc] init];
    FlutterEventChannel *headingChanel = [FlutterEventChannel eventChannelWithName:@"amap_location/heading" binaryMessenger:registrar.messenger];
    
    [locationChanel setStreamHandler:locationStreamHandler];
    [headingChanel setStreamHandler:headingStreamHandler];
}


 + (double)transformLat:(double)x bdLon:(double)y
{
    double ret = LAT_OFFSET_0(x, y);
    ret += LAT_OFFSET_1;
    ret += LAT_OFFSET_2;
    ret += LAT_OFFSET_3;
    return ret;
}

+ (double)transformLon:(double)x bdLon:(double)y
{
    double ret = LON_OFFSET_0(x, y);
    ret += LON_OFFSET_1;
    ret += LON_OFFSET_2;
    ret += LON_OFFSET_3;
    return ret;
}

+ (CLLocationCoordinate2D)gcj02Encrypt:(double)ggLat bdLon:(double)ggLon
{
    CLLocationCoordinate2D resPoint;
    double mgLat;
    double mgLon;
    double dLat = [self transformLat:(ggLon - 105.0)bdLon:(ggLat - 35.0)];
    double dLon = [self transformLon:(ggLon - 105.0) bdLon:(ggLat - 35.0)];
    double radLat = ggLat / 180.0 * M_PI;
    double magic = sin(radLat);
    magic = 1 - jzEE * magic * magic;
    double sqrtMagic = sqrt(magic);
    dLat = (dLat * 180.0) / ((jzA * (1 - jzEE)) / (magic * sqrtMagic) * M_PI);
    dLon = (dLon * 180.0) / (jzA / sqrtMagic * cos(radLat) * M_PI);
    mgLat = ggLat + dLat;
    mgLon = ggLon + dLon;
    
    resPoint.latitude = mgLat;
    resPoint.longitude = mgLon;
    return resPoint;
}

+ (CLLocationCoordinate2D)gcj02Decrypt:(double)gjLat gjLon:(double)gjLon {
    CLLocationCoordinate2D  gPt = [self gcj02Encrypt:gjLat bdLon:gjLon];
    double dLon = gPt.longitude - gjLon;
    double dLat = gPt.latitude - gjLat;
    CLLocationCoordinate2D pt;
    pt.latitude = gjLat - dLat;
    pt.longitude = gjLon - dLon;
    return pt;
}

+ (CLLocationCoordinate2D)gcj02ToWgs84:(CLLocationCoordinate2D)location
{
    return [self gcj02Decrypt:location.latitude gjLon:location.longitude];
}




- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSString* method = call.method;
    
    if ([@"startup" isEqualToString:method]) {
        //启动系统
        result(@([self startup:call.arguments]));
    }else if([@"shutdown" isEqualToString:method]){
        //关闭系统
        result(@([self shutdown]));
    }else if([@"getLocation" isEqualToString:method]){
        //进行单次定位请求
        [self getLocation: [call.arguments boolValue] result:result];
        
    }else if([@"stopLocation" isEqualToString:method]){
        //停止监听位置改变
        result(@([self stopLocation]));
    }else if([@"startLocation" isEqualToString:method]){
        //开始监听位置改变
        result(@([self startLocation]));
    }else if( [@"updateOption" isEqualToString:method] ){
        
        result(@([self updateOption:call.arguments]));
        
    }else if([@"setApiKey" isEqualToString:method]){
        [AMapServices sharedServices].apiKey = call.arguments;

        result(@YES);
    } else if([@"satrtHeading" isEqualToString:method]){
        //开始监听方向变化
        result(@([self startHeading]));
    } else if([@"stopHeading" isEqualToString:method]){
        //开始监听方向变化
        result(@([self stopHeading]));
    } else {
        result(FlutterMethodNotImplemented);
    }
}

-(double)getDesiredAccuracy:(NSString*)str{
    
    if([@"kCLLocationAccuracyBest" isEqualToString:str]){
        return kCLLocationAccuracyBest;
    }else if([@"kCLLocationAccuracyNearestTenMeters" isEqualToString:str]){
        return kCLLocationAccuracyNearestTenMeters;
    }else if([@"kCLLocationAccuracyHundredMeters" isEqualToString:str]){
        return kCLLocationAccuracyHundredMeters;
    }
    else if([@"kCLLocationAccuracyKilometer" isEqualToString:str]){
        return kCLLocationAccuracyKilometer;
    }
    else{
        return kCLLocationAccuracyThreeKilometers;
    }

    
}

-(BOOL)updateOption:(NSDictionary*)args{
    if(locationManager){
     
        //设置期望定位精度
        [locationManager setDesiredAccuracy:[ self getDesiredAccuracy: args[@"desiredAccuracy"]]];
        
        NSLog(@"%@",args);
        
        [locationManager setPausesLocationUpdatesAutomatically:[args[@"pausesLocationUpdatesAutomatically"] boolValue]];
        
        [locationManager setDistanceFilter: [args[@"distanceFilter"] doubleValue]];
        
        //设置在能不能再后台定位
        [locationManager setAllowsBackgroundLocationUpdates:[args[@"allowsBackgroundLocationUpdates"] boolValue]];
        
        //设置定位超时时间
        [locationManager setLocationTimeout:[args[@"locationTimeout"] integerValue]];
        
        //设置逆地理超时时间
        [locationManager setReGeocodeTimeout:[args[@"reGeocodeTimeout"] integerValue]];
        
        //定位是否需要逆地理信息
        [locationManager setLocatingWithReGeocode:[args[@"locatingWithReGeocode"] boolValue]];
        
        ///检测是否存在虚拟定位风险，默认为NO，不检测。 \n注意:设置为YES时，单次定位通过 AMapLocatingCompletionBlock 的error给出虚拟定位风险提示；连续定位通过 amapLocationManager:didFailWithError: 方法的error给出虚拟定位风险提示。error格式为error.domain==AMapLocationErrorDomain; error.code==AMapLocationErrorRiskOfFakeLocation;
        [locationManager setDetectRiskOfFakeLocation: [args[@"detectRiskOfFakeLocation"] boolValue ]];
        
        //设置是否转换坐标
        isConvertToWGS84 = [args[@"isConvertToWGS84"] boolValue];
        return YES;

    }
    return NO;
}

-(BOOL)startLocation{
    if(locationManager){
        [locationManager startUpdatingLocation];
        return YES;
    }
    return NO;
}

-(BOOL)stopLocation{
    if(locationManager){
        [locationManager stopUpdatingLocation];
        return YES;
    }
    return NO;
}

-(BOOL)startHeading{
    if(locationManager){
        [locationManager startUpdatingHeading];
        return YES;
    }
    return NO;
}

-(BOOL)stopHeading{
    if(locationManager){
        [locationManager stopUpdatingHeading];
        return YES;
    }
    return NO;
}

-(void)getLocation:(BOOL)withReGeocode result:(FlutterResult)result{
    
    completionBlock = ^(CLLocation *location, AMapLocationReGeocode *regeocode, NSError *error){
        
        if (error != nil && error.code == AMapLocationErrorLocateFailed)
        {
            //定位错误：此时location和regeocode没有返回值，不进行annotation的添加
            NSLog(@"定位错误:{%ld - %@};", (long)error.code, error.localizedDescription);
            result(@{ @"code":@(error.code),@"description":error.localizedDescription, @"success":@NO });
            return;
        }
        else if (error != nil
                 && (error.code == AMapLocationErrorReGeocodeFailed
                     || error.code == AMapLocationErrorTimeOut
                     || error.code == AMapLocationErrorCannotFindHost
                     || error.code == AMapLocationErrorBadURL
                     || error.code == AMapLocationErrorNotConnectedToInternet
                     || error.code == AMapLocationErrorCannotConnectToHost))
        {
            //逆地理错误：在带逆地理的单次定位中，逆地理过程可能发生错误，此时location有返回值，regeocode无返回值，进行annotation的添加
            NSLog(@"逆地理错误:{%ld - %@};", (long)error.code, error.localizedDescription);
        }
        else if (error != nil && error.code == AMapLocationErrorRiskOfFakeLocation)
        {
            //存在虚拟定位的风险：此时location和regeocode没有返回值，不进行annotation的添加
            NSLog(@"存在虚拟定位的风险:{%ld - %@};", (long)error.code, error.localizedDescription);
            result(@{ @"code":@(error.code),@"description":error.localizedDescription, @"success":@NO  });
            return;
        }
        else
        {
            //没有错误：location有返回值，regeocode是否有返回值取决于是否进行逆地理操作，进行annotation的添加
        }
        
        NSMutableDictionary* md = [[NSMutableDictionary alloc]initWithDictionary: [AmapLocationPlugin location2map:location]  ];
        if (regeocode)
        {
            [md addEntriesFromDictionary:[AmapLocationPlugin regeocode2map:regeocode]];
            md[@"code"] = @0;
            md[@"success"] = @YES;
        }
        else
        {
            md[@"code"]=@(error.code);
            md[@"description"]=error.localizedDescription;
            md[@"success"] = @YES;
        }
        
        result(md);
        
    };
    [locationManager requestLocationWithReGeocode:withReGeocode completionBlock:completionBlock];
    
 //   [self.locationManager startUpdatingLocation];
}


+(id)checkNull:(NSObject*)value{
    return value == nil ? [NSNull null] : value;
}

+(NSDictionary*)regeocode2map:(AMapLocationReGeocode *)regeocode{
    return @{@"formattedAddress":regeocode.formattedAddress,
             @"country":regeocode.country,
             @"province":regeocode.province,
             @"city":regeocode.city,
             @"district":regeocode.district,
             @"citycode":regeocode.citycode,
             @"adcode":regeocode.adcode,
             @"street":regeocode.street,
             @"number":regeocode.number,
             @"POIName":[self checkNull : regeocode.POIName],
             @"AOIName":[self checkNull :regeocode.AOIName],
             };
}

+(NSDictionary*)location2map:(CLLocation *)location{
    
    CLLocationCoordinate2D wpt;
    wpt.latitude =location.coordinate.latitude;
    wpt.longitude =location.coordinate.longitude;
    if (isConvertToWGS84){
        wpt = [self gcj02ToWgs84:wpt];
    }
    return @{@"latitude": @(wpt.latitude),
             @"longitude": @(wpt.longitude),
             @"accuracy": @((location.horizontalAccuracy + location.verticalAccuracy)/2),
             @"altitude": @(location.altitude),
             @"speed": @(location.speed),
             @"bearing": @(location.course),
             @"timestamp": @(location.timestamp.timeIntervalSince1970),};
    
}


-(BOOL)startup:(NSDictionary*)args{
    if(locationManager)return NO;
    
    locationManager = [[AMapLocationManager alloc] init];
    
    [locationManager setDelegate:self];

    return [self updateOption:args];
}


-(BOOL)shutdown{
    if(locationManager){
        //停止定位
        [locationManager stopUpdatingLocation];
        [locationManager stopUpdatingHeading];
        [locationManager setDelegate:nil];
        locationManager = nil;
        
        return YES;
    }
    return NO;
    
}
/**
 *  @brief 连续定位回调函数.注意：如果实现了本方法，则定位信息不会通过amapLocationManager:didUpdateLocation:方法回调。
 *  @param manager 定位 AMapLocationManager 类。
 *  @param location 定位结果。
 *  @param reGeocode 逆地理信息。
 */
- (void)amapLocationManager:(AMapLocationManager *)manager didUpdateLocation:(CLLocation *)location reGeocode:(AMapLocationReGeocode *)reGeocode{
    
   // NSMutableDictionary* md = [[NSMutableDictionary alloc]initWithDictionary: [AmapLocationPlugin location2map:location]  ];
//    if(reGeocode){
//        [md addEntriesFromDictionary:[ AmapLocationPlugin regeocode2map:reGeocode ]];
//    }
//
//    md[@"success"]=@YES;
//
//    [self.channel invokeMethod:@"updateLocation" arguments:md];
    
    flutterLocationEventSink([AmapLocationPlugin location2map:location]);
    
}


+(NSDictionary*)heading2map:(CLLocationDirection )newHeading{
    return @{@"heading":@(newHeading)};
}

/**
*
*/
- (void)amapLocationManager:(AMapLocationManager *)manager didUpdateHeading:(CLHeading *)newHeading{

    
    if(newHeading.headingAccuracy>0){
        CLLocationDirection heading;
        heading = newHeading.trueHeading > 0 ? newHeading.trueHeading : newHeading.magneticHeading;
        
//        NSMutableDictionary* md = [[NSMutableDictionary alloc]initWithDictionary: [AmapLocationPlugin heading2map:heading] ];
//
//        md[@"success"]=@YES;
//
//        [channel invokeMethod:@"updateHeading" arguments:md];
        NSLog(@"%@", @(heading));
        flutterHeadingEventSink([AmapLocationPlugin heading2map:heading]);
    }

}




/**
 *  @brief 定位权限状态改变时回调函数
 *  @param manager 定位 AMapLocationManager 类。
 *  @param status 定位权限状态。
 */
- (void)amapLocationManager:(AMapLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status{
    
}


/**
 *  @brief 当定位发生错误时，会调用代理的此方法。
 *  @param manager 定位 AMapLocationManager 类。
 *  @param error 返回的错误，参考 CLError 。
 */
- (void)amapLocationManager:(AMapLocationManager *)manager didFailWithError:(NSError *)error{
    
    NSLog(@"定位错误:{%ld - %@};", (long)error.code, error.localizedDescription);

    
    
    [channel invokeMethod:@"updateLocation" arguments:@{ @"code":@(error.code),@"description":error.localizedDescription,@"success":@NO }];

    

    
}
@end

@implementation LocationStreamHandler
-(FlutterError*)onListenWithArguments:(id)arguments eventSink:(FlutterEventSink)events {
    flutterLocationEventSink = events;
    return nil;
}

-(FlutterError*)onCancelWithArguments:(id)arguments {
    return nil;
}
@end

@implementation HeadingStreamHandler
-(FlutterError*)onListenWithArguments:(id)arguments eventSink:(FlutterEventSink)events {
    flutterHeadingEventSink = events;
    return nil;
}

-(FlutterError*)onCancelWithArguments:(id)arguments {
    return nil;
}
@end
