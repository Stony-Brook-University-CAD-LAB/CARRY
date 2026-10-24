#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <limits>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "geometry_msgs/msg/twist.hpp"
#include "rcl_interfaces/msg/set_parameters_result.hpp"
#include "rclcpp/rclcpp.hpp"
#include "sensor_msgs/msg/image.hpp"
#include "std_msgs/msg/string.hpp"

using namespace std::chrono_literals;

class ObstacleAvoidance : public rclcpp::Node {
public:
  ObstacleAvoidance() : Node("obstacle_avoidance") {
    caution_distance_ = declare_parameter<double>("caution_distance", 1.0);
    stop_distance_ = declare_parameter<double>("stop_distance", 0.50);
    too_close_distance_ = declare_parameter<double>("too_close_distance", 0.25);
    scan_clearance_ = declare_parameter<double>("scan_clearance", 0.75);
    reverse_time_s_ = declare_parameter<double>("reverse_time_s", 0.8);
    turn_time_s_ = declare_parameter<double>("turn_time_s", 0.65);
    settle_time_s_ = declare_parameter<double>("settle_time_s", 0.35);
    forward_speed_ = declare_parameter<double>("forward_speed", 0.20);
    reverse_speed_ = declare_parameter<double>("reverse_speed", -0.15);
    turn_speed_ = declare_parameter<double>("turn_speed", 0.50);
    stop_for_person_ = declare_parameter<bool>("stop_for_person", true);
    person_hold_s_ = declare_parameter<double>("person_hold_s", 0.75);
    person_confirm_frames_ = declare_parameter<int>("person_confirm_frames", 3);
    person_clear_frames_ = declare_parameter<int>("person_clear_frames", 3);
    person_stop_distance_ = declare_parameter<double>("person_stop_distance", 1.5);
    enabled_ = declare_parameter<bool>("enabled", false);

    // Camera geometry, used to turn depth pixels into 3D points so the floor
    // and anything outside the rover's path are ignored. Measure these on the
    // rover: height of the lens above the floor and downward tilt.
    camera_height_ = declare_parameter<double>("camera_height", 0.20);
    camera_pitch_ = declare_parameter<double>("camera_pitch_deg", 0.0) * M_PI / 180.0;
    fx_ = declare_parameter<double>("fx", 570.0);
    fy_ = declare_parameter<double>("fy", 570.0);
    cx_ = declare_parameter<double>("cx", -1.0);  // <0: image centre
    cy_ = declare_parameter<double>("cy", -1.0);
    robot_width_ = declare_parameter<double>("robot_width", 0.30);
    side_margin_ = declare_parameter<double>("side_margin", 0.05);
    side_window_ = declare_parameter<double>("side_window", 0.40);
    floor_margin_ = declare_parameter<double>("floor_margin", 0.04);
    max_obstacle_height_ = declare_parameter<double>("max_obstacle_height", 0.50);
    max_range_ = declare_parameter<double>("max_range", 4.0);
    min_points_ = declare_parameter<int>("min_points", 20);
    sample_step_ = std::max(1, static_cast<int>(declare_parameter<int>("sample_step", 4)));
    filter_frames_ = std::max(1, static_cast<int>(declare_parameter<int>("filter_frames", 3)));
    no_depth_fraction_ = declare_parameter<double>("no_depth_fraction", 0.6);
    rgb_width_ = declare_parameter<int>("rgb_width", 640);
    rgb_height_ = declare_parameter<int>("rgb_height", 480);

    cmd_pub_ = create_publisher<geometry_msgs::msg::Twist>("/cmd_vel", 10);
    status_pub_ = create_publisher<std_msgs::msg::String>("/navigation/status", 10);

    depth_sub_ = create_subscription<sensor_msgs::msg::Image>(
      "/camera/depth/image_raw", 10,
      std::bind(&ObstacleAvoidance::depth_callback, this, std::placeholders::_1));
    yolo_sub_ = create_subscription<std_msgs::msg::String>(
      "/yolo/detections", 10,
      std::bind(&ObstacleAvoidance::yolo_callback, this, std::placeholders::_1));

    timer_ = create_wall_timer(50ms, std::bind(&ObstacleAvoidance::control_loop, this));
    param_cb_ = add_on_set_parameters_callback(
      std::bind(&ObstacleAvoidance::parameters_callback, this, std::placeholders::_1));
    state_start_ = now();
    last_person_seen_ = rclcpp::Time(0, 0, get_clock()->get_clock_type());
    RCLCPP_INFO(get_logger(), "Obstacle avoidance ready (depth + YOLO person stop)");
  }

private:
  enum class State {
    DRIVE,
    STOP_BEFORE_SCAN,
    TURN_LEFT_SCAN,
    SETTLE_LEFT,
    TURN_RIGHT_SCAN,
    SETTLE_RIGHT,
    RETURN_CENTER,
    SETTLE_CENTER,
    REVERSE,
    AVOID_TURN,
    BLOCKED
  };

  struct Clearance {
    double left;
    double center;
    double right;
    bool no_depth;  // centre too close for the camera to measure
  };

  void depth_callback(const sensor_msgs::msg::Image::SharedPtr msg) {
    if (msg->encoding != "16UC1" || msg->data.empty()) return;
    width_ = static_cast<int>(msg->width);
    height_ = static_cast<int>(msg->height);
    step_ = static_cast<int>(msg->step);
    depth_ = msg->data;
    have_depth_ = true;
    last_depth_ = now();

    history_.push_back(measure());
    while (static_cast<int>(history_.size()) > filter_frames_) history_.erase(history_.begin());
  }

  uint16_t depth_at(int x, int y) const {
    const size_t offset = static_cast<size_t>(y) * step_ + static_cast<size_t>(x) * 2;
    if (offset + 1 >= depth_.size()) return 0;
    uint16_t mm = 0;
    std::memcpy(&mm, &depth_[offset], sizeof(mm));
    return mm;
  }

  // Projects the depth image into 3D, drops floor points and anything too
  // high to hit, and reports the nearest obstacle ahead in three lanes:
  // the rover's own path (centre) and a window either side of it.
  Clearance measure() const {
    const double inf = std::numeric_limits<double>::infinity();
    const double cx = cx_ >= 0.0 ? cx_ : width_ / 2.0;
    const double cy = cy_ >= 0.0 ? cy_ : height_ / 2.0;
    const double half_path = robot_width_ / 2.0 + side_margin_;
    const double cos_p = std::cos(camera_pitch_);
    const double sin_p = std::sin(camera_pitch_);

    std::vector<double> left, center, right;
    int lower_total = 0, lower_missing = 0;

    for (int y = 0; y < height_; y += sample_step_) {
      for (int x = 0; x < width_; x += sample_step_) {
        const uint16_t mm = depth_at(x, y);

        // The Astra returns 0 for anything closer than ~0.4 m. Track missing
        // depth in the lower-middle of the image, where the floor is normally
        // visible, so a very close obstacle reads as blocked, not clear.
        if (x >= width_ / 3 && x < 2 * width_ / 3 && y >= height_ / 2 && y < height_ * 9 / 10) {
          ++lower_total;
          if (mm == 0) ++lower_missing;
        }
        if (mm < 100 || mm > 8000) continue;

        const double z = mm / 1000.0;
        const double px = (x - cx) * z / fx_;  // right of the camera
        const double py = (y - cy) * z / fy_;  // below the camera
        const double forward = z * cos_p - py * sin_p;
        const double height = camera_height_ - (py * cos_p + z * sin_p);
        if (forward <= 0.0 || forward > max_range_) continue;
        if (height < floor_margin_ || height > max_obstacle_height_) continue;

        if (std::abs(px) <= half_path) center.push_back(forward);
        else if (px < 0.0 && px >= -(half_path + side_window_)) left.push_back(forward);
        else if (px > 0.0 && px <= half_path + side_window_) right.push_back(forward);
      }
    }

    // Nearest obstacle in a lane, ignoring isolated noisy pixels.
    auto nearest = [this, inf](std::vector<double> &d) {
      if (static_cast<int>(d.size()) < min_points_) return inf;
      const size_t idx = std::max<size_t>(static_cast<size_t>(min_points_) / 2, d.size() / 20);
      std::nth_element(d.begin(), d.begin() + idx, d.end());
      return d[idx];
    };

    Clearance c{nearest(left), nearest(center), nearest(right), false};
    if (lower_total > 0 &&
        static_cast<double>(lower_missing) / lower_total >= no_depth_fraction_) {
      c.no_depth = true;
      c.center = 0.0;
    }
    return c;
  }

  // Median of the last few frames, so one noisy frame cannot trigger a stop
  // or hide an obstacle.
  Clearance clearance() const {
    const double inf = std::numeric_limits<double>::infinity();
    if (history_.empty()) return {inf, inf, inf, false};
    auto median = [this](double Clearance::*field) {
      std::vector<double> v;
      for (const auto &c : history_) v.push_back(c.*field);
      std::nth_element(v.begin(), v.begin() + v.size() / 2, v.end());
      return v[v.size() / 2];
    };
    int no_depth = 0;
    for (const auto &c : history_) no_depth += c.no_depth ? 1 : 0;
    return {median(&Clearance::left), median(&Clearance::center), median(&Clearance::right),
            no_depth * 2 > static_cast<int>(history_.size())};
  }

  // Distance to the nearest point inside a YOLO box (RGB pixel coordinates),
  // read from the depth image. The Astra's RGB and depth views are close
  // enough at 640x480 for this rough check.
  double box_distance(double bx, double by, double bw, double bh) const {
    if (!have_depth_ || width_ <= 0 || height_ <= 0) return std::numeric_limits<double>::infinity();
    const double sx = static_cast<double>(width_) / rgb_width_;
    const double sy = static_cast<double>(height_) / rgb_height_;
    const int x0 = std::clamp(static_cast<int>((bx + 0.25 * bw) * sx), 0, width_ - 1);
    const int x1 = std::clamp(static_cast<int>((bx + 0.75 * bw) * sx), x0 + 1, width_);
    const int y0 = std::clamp(static_cast<int>((by + 0.25 * bh) * sy), 0, height_ - 1);
    const int y1 = std::clamp(static_cast<int>((by + 0.75 * bh) * sy), y0 + 1, height_);
    std::vector<uint16_t> samples;
    for (int y = y0; y < y1; y += sample_step_) {
      for (int x = x0; x < x1; x += sample_step_) {
        const uint16_t mm = depth_at(x, y);
        if (mm >= 100 && mm <= 8000) samples.push_back(mm);
      }
    }
    if (samples.size() < 5) return std::numeric_limits<double>::infinity();
    const size_t idx = samples.size() / 5;
    std::nth_element(samples.begin(), samples.begin() + idx, samples.end());
    return samples[idx] / 1000.0;
  }

  static double json_number(const std::string &obj, const std::string &key) {
    const auto pos = obj.find("\"" + key + "\":");
    if (pos == std::string::npos) return std::nan("");
    return std::strtod(obj.c_str() + pos + key.size() + 3, nullptr);
  }

  // A person only blocks the rover when they overlap its path and are within
  // person_stop_distance; people off to the side or far away are ignored.
  bool person_in_path(const std::string &json) const {
    const double half_path_px = (robot_width_ / 2.0 + side_margin_) * fx_ / std::max(0.5, person_stop_distance_);
    const double path_x0 = rgb_width_ / 2.0 - half_path_px;
    const double path_x1 = rgb_width_ / 2.0 + half_path_px;

    size_t start = 0;
    while ((start = json.find('{', start)) != std::string::npos) {
      const size_t end = json.find('}', start);
      if (end == std::string::npos) break;
      const std::string obj = json.substr(start, end - start + 1);
      start = end + 1;
      if (obj.find("\"class\":\"person\"") == std::string::npos) continue;

      const double bx = json_number(obj, "x");
      const double by = json_number(obj, "y");
      const double bw = json_number(obj, "w");
      const double bh = json_number(obj, "h");
      if (std::isnan(bx) || std::isnan(bw)) return true;  // old message format: be safe
      if (bx + bw < path_x0 || bx > path_x1) continue;
      if (box_distance(bx, by, bw, bh) <= person_stop_distance_) return true;
    }
    return false;
  }

  void yolo_callback(const std_msgs::msg::String::SharedPtr msg) {
    if (!stop_for_person_) return;

    const bool person_detected = person_in_path(msg->data);

    if (person_detected) {
      last_person_seen_ = now();
      person_clear_count_ = 0;
      if (person_detect_count_ < person_confirm_frames_) ++person_detect_count_;

      if (!person_blocking_ && person_detect_count_ >= person_confirm_frames_) {
        person_blocking_ = true;
        person_avoidance_ = true;
        set_state(State::STOP_BEFORE_SCAN);
        RCLCPP_WARN(
          get_logger(), "PERSON CONFIRMED for %d detection frames: stopping and scanning for alternate path",
          person_detect_count_);
      }
    } else {
      person_detect_count_ = 0;
      if (person_blocking_) {
        ++person_clear_count_;
        if (person_clear_count_ >= person_clear_frames_) {
          person_blocking_ = false;
          person_clear_count_ = 0;
          set_state(State::DRIVE);
          RCLCPP_INFO(
            get_logger(), "Person absent for %d detection frames: resuming depth navigation",
            person_clear_frames_);
        }
      }
    }
  }

  bool person_recent() const {
    if (!stop_for_person_ || !person_blocking_) return false;
    if (last_person_seen_.nanoseconds() == 0) return false;
    return (now() - last_person_seen_).seconds() <= person_hold_s_;
  }

  void publish_cmd(double linear, double angular) {
    geometry_msgs::msg::Twist cmd;
    cmd.linear.x = linear;
    cmd.angular.z = angular;
    cmd_pub_->publish(cmd);
  }

  void publish_status(const std::string &mode, double distance) {
    std_msgs::msg::String msg;
    std::ostringstream out;
    out << mode;
    if (std::isfinite(distance)) {
      out << " | " << std::fixed << std::setprecision(2) << distance << " m";
    }
    msg.data = out.str();
    status_pub_->publish(msg);
  }

  void set_state(State s) {
    state_ = s;
    state_start_ = now();
  }

  double elapsed() const { return (now() - state_start_).seconds(); }

  rcl_interfaces::msg::SetParametersResult parameters_callback(
      const std::vector<rclcpp::Parameter> &params) {
    rcl_interfaces::msg::SetParametersResult result;
    result.successful = true;

    for (const auto &p : params) {
      if (p.get_name() != "enabled") continue;
      const bool enable = p.as_bool();
      if (enable && !enabled_) {
        set_state(State::DRIVE);
        RCLCPP_INFO(get_logger(), "Autonomous enabled");
      } else if (!enable && enabled_) {
        // Stop once so the rover does not keep the last autonomous command.
        publish_cmd(0.0, 0.0);
        RCLCPP_INFO(get_logger(), "Autonomous disabled");
      }
      enabled_ = enable;
    }

    return result;
  }

  void control_loop() {
    // While disabled, stay off /cmd_vel so manual control is not overridden.
    if (!enabled_) {
      publish_status("MANUAL", std::numeric_limits<double>::infinity());
      return;
    }

    if (!have_depth_ || (now() - last_depth_).seconds() > 0.5) {
      publish_cmd(0.0, 0.0);
      publish_status("DEPTH LOST - STOP", std::numeric_limits<double>::infinity());
      return;
    }

    const Clearance view = clearance();
    const double center = view.center;

    if (person_recent() && state_ == State::DRIVE) {
      publish_cmd(0.0, 0.0);
      publish_status("PERSON DETECTED - STOP", center);
      return;
    }

    switch (state_) {
      case State::DRIVE:
        if (center <= too_close_distance_) {
          publish_cmd(0.0, 0.0);
          publish_status(view.no_depth ? "TOO CLOSE (NO DEPTH) - SCANNING" : "TOO CLOSE - SCANNING", center);
          RCLCPP_WARN(get_logger(), "TOO CLOSE %.2f m: stop, scan left/right before reversing", center);
          set_state(State::STOP_BEFORE_SCAN);
        } else if (center <= stop_distance_) {
          publish_cmd(0.0, 0.0);
          publish_status("OBSTACLE - AVOIDING", center);
          avoid_left_ = view.left >= view.right;
          RCLCPP_INFO(get_logger(), "Obstacle %.2f m: turning %s (L=%.2f R=%.2f)",
                      center, avoid_left_ ? "left" : "right", view.left, view.right);
          set_state(State::AVOID_TURN);
        } else if (center <= caution_distance_) {
          publish_cmd(forward_speed_, 0.0);
          publish_status("CAUTION", center);
        } else {
          publish_cmd(forward_speed_, 0.0);
          publish_status("PATH CLEAR", center);
        }
        break;

      case State::STOP_BEFORE_SCAN:
        publish_cmd(0.0, 0.0);
        publish_status(person_avoidance_ ? "PERSON - PREPARING SCAN" : "STOPPED - PREPARING SCAN", center);
        if (elapsed() >= settle_time_s_) set_state(State::TURN_LEFT_SCAN);
        break;

      case State::TURN_LEFT_SCAN:
        publish_cmd(0.0, turn_speed_);
        publish_status("SCANNING LEFT", center);
        if (elapsed() >= turn_time_s_) {
          publish_cmd(0.0, 0.0);
          set_state(State::SETTLE_LEFT);
        }
        break;

      case State::SETTLE_LEFT:
        publish_cmd(0.0, 0.0);
        publish_status("MEASURING LEFT", center);
        if (elapsed() >= settle_time_s_) {
          left_scan_ = center;
          RCLCPP_INFO(get_logger(), "Left scan: %.2f m", left_scan_);
          set_state(State::TURN_RIGHT_SCAN);
        }
        break;

      case State::TURN_RIGHT_SCAN:
        publish_cmd(0.0, -turn_speed_);
        publish_status("SCANNING RIGHT", center);
        if (elapsed() >= 2.0 * turn_time_s_) {
          publish_cmd(0.0, 0.0);
          set_state(State::SETTLE_RIGHT);
        }
        break;

      case State::SETTLE_RIGHT:
        publish_cmd(0.0, 0.0);
        publish_status("MEASURING RIGHT", center);
        if (elapsed() >= settle_time_s_) {
          right_scan_ = center;
          RCLCPP_INFO(get_logger(), "Right scan: %.2f m", right_scan_);
          set_state(State::RETURN_CENTER);
        }
        break;

      case State::RETURN_CENTER:
        publish_cmd(0.0, turn_speed_);
        publish_status("RETURNING CENTER", center);
        if (elapsed() >= turn_time_s_) {
          publish_cmd(0.0, 0.0);
          set_state(State::SETTLE_CENTER);
        }
        break;

      case State::SETTLE_CENTER:
        publish_cmd(0.0, 0.0);
        publish_status("EVALUATING PATH", center);
        if (elapsed() >= settle_time_s_) {
          if (person_avoidance_) {
            const bool left_clear = left_scan_ >= scan_clearance_;
            const bool right_clear = right_scan_ >= scan_clearance_;
            if (left_clear || right_clear) {
              avoid_left_ = left_clear && (!right_clear || left_scan_ >= right_scan_);
              person_avoidance_ = false;
              person_blocking_ = false;
              person_detect_count_ = 0;
              person_clear_count_ = 0;
              RCLCPP_WARN(
                get_logger(), "Person alternate path selected: %s (L=%.2f R=%.2f)",
                avoid_left_ ? "LEFT" : "RIGHT", left_scan_, right_scan_);
              set_state(State::AVOID_TURN);
            } else {
              RCLCPP_ERROR(
                get_logger(), "No clear alternate path around person: L=%.2f R=%.2f",
                left_scan_, right_scan_);
              set_state(State::BLOCKED);
            }
          } else if (left_scan_ >= scan_clearance_ && right_scan_ >= scan_clearance_) {
            RCLCPP_WARN(get_logger(), "Scan clear L=%.2f R=%.2f: short reverse", left_scan_, right_scan_);
            set_state(State::REVERSE);
          } else {
            RCLCPP_ERROR(get_logger(), "Reverse rejected: scan not clear L=%.2f R=%.2f", left_scan_, right_scan_);
            set_state(State::BLOCKED);
          }
        }
        break;

      case State::REVERSE:
        publish_cmd(reverse_speed_, 0.0);
        publish_status("REVERSING", center);
        if (elapsed() >= reverse_time_s_) {
          publish_cmd(0.0, 0.0);
          avoid_left_ = left_scan_ >= right_scan_;
          set_state(State::AVOID_TURN);
        }
        break;

      case State::AVOID_TURN:
        publish_cmd(0.0, avoid_left_ ? turn_speed_ : -turn_speed_);
        publish_status(avoid_left_ ? "AVOIDING - TURN LEFT" : "AVOIDING - TURN RIGHT", center);
        if (elapsed() >= turn_time_s_) {
          publish_cmd(0.0, 0.0);
          set_state(State::DRIVE);
        }
        break;

      case State::BLOCKED:
        publish_cmd(0.0, 0.0);
        publish_status(person_avoidance_ ? "PERSON/BLOCKED - STOP" : "BLOCKED - STOP", center);
        if (center > stop_distance_ && !person_recent()) {
          person_avoidance_ = false;
          set_state(State::DRIVE);
        }
        break;
    }
  }

  State state_{State::DRIVE};
  bool enabled_{false};
  std::vector<Clearance> history_;
  rclcpp::Time state_start_;
  rclcpp::Time last_depth_;
  rclcpp::Time last_person_seen_;
  bool have_depth_{false};
  bool avoid_left_{true};
  bool person_blocking_{false};
  bool person_avoidance_{false};
  int width_{0}, height_{0}, step_{0};
  std::vector<uint8_t> depth_;
  double left_scan_{0.0}, right_scan_{0.0};

  double caution_distance_{1.0};
  double stop_distance_{0.50};
  double too_close_distance_{0.25};
  double scan_clearance_{0.75};
  double reverse_time_s_{0.8};
  double turn_time_s_{0.65};
  double settle_time_s_{0.35};
  double forward_speed_{0.20};
  double reverse_speed_{-0.15};
  double turn_speed_{0.50};
  bool stop_for_person_{true};
  double person_hold_s_{0.75};
  int person_confirm_frames_{3};
  int person_clear_frames_{3};
  int person_detect_count_{0};
  int person_clear_count_{0};
  double person_stop_distance_{1.5};

  double camera_height_{0.20};
  double camera_pitch_{0.0};
  double fx_{570.0}, fy_{570.0}, cx_{-1.0}, cy_{-1.0};
  double robot_width_{0.30};
  double side_margin_{0.05};
  double side_window_{0.40};
  double floor_margin_{0.04};
  double max_obstacle_height_{0.50};
  double max_range_{4.0};
  int min_points_{20};
  int sample_step_{4};
  int filter_frames_{3};
  double no_depth_fraction_{0.6};
  int rgb_width_{640};
  int rgb_height_{480};

  rclcpp::Publisher<geometry_msgs::msg::Twist>::SharedPtr cmd_pub_;
  rclcpp::Publisher<std_msgs::msg::String>::SharedPtr status_pub_;
  rclcpp::Subscription<sensor_msgs::msg::Image>::SharedPtr depth_sub_;
  rclcpp::Subscription<std_msgs::msg::String>::SharedPtr yolo_sub_;
  rclcpp::TimerBase::SharedPtr timer_;
  rclcpp::node_interfaces::OnSetParametersCallbackHandle::SharedPtr param_cb_;
};

int main(int argc, char **argv) {
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<ObstacleAvoidance>());
  rclcpp::shutdown();
  return 0;
}
